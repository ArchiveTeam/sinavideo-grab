local urlparse = require("socket.url")
local https = require("ssl.https")
local cjson = require("cjson")
local utf8 = require("utf8")
local html_entities = require("htmlEntities")
local basexx = require("basexx")
local openssl_digest = require("openssl.digest")

local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")
local item_type = nil
local item_name = nil
local item_value = nil

local url_count = 0
local tries = 0
local downloaded = {}
local addedtolist = {}
local abortgrab = false
local killgrab = false
local logged_response = false
local status_code = 0
local content_type = ""

local discovered_outlinks = {}
local discovered_items = {}
local bad_items = {}
local ids = {}

local retry_url = false
local context = {}

local item_patterns = {
  ["^https?://api%.ivideo%.sina%.com%.cn/public/video/info%?.*video_id=([0-9]+)"] = "video",
  ["^https?://s%.video%.sina%.com%.cn/video/getvideoidbyvid%?.*vid=([0-9]+)"] = "vid",
}

abort_item = function(item)
  abortgrab = true
  if not item then
    item = item_name
  end
  if not bad_items[item] then
    io.stdout:write("Aborting item " .. item .. ".\n")
    io.stdout:flush()
    bad_items[item] = true
  end
end

kill_grab = function(item)
  io.stdout:write("Aborting crawling.\n")
  io.stdout:flush()
  killgrab = true
end

read_file = function(file)
  if file then
    local f = assert(io.open(file, "rb"))
    local body = f:read("*all")
    f:close()
    return body
  else
    return ""
  end
end

processed = function(url)
  if downloaded[url] or addedtolist[url] then
    return true
  end
  return false
end

discover_item = function(target, item)
  if item ~= item_name and not target[item] then
    target[item] = true
    return true
  end
  return false
end

percent_encode_url = function(newurl)
  return string.gsub(newurl, "(.)", function(c)
    local b = string.byte(c)
    if b < 32 or b > 126 then
      return string.format("%%%02X", b)
    end
    return c
  end)
end

find_item = function(url)
  for pattern, type_ in pairs(item_patterns) do
    local value = string.match(url, pattern)
    if value then
      return {
        ["value"]=urlparse.unescape(value),
        ["type"]=type_
      }
    end
  end
end

set_item = function(url)
  if ids[string.lower(url)] then
    return nil
  end
  local found = find_item(url)
  if found then
    local new_item_type = found["type"]
    local new_item_value = found["value"]
    local new_item_name = new_item_type .. ":" .. new_item_value
    if new_item_type == "vid" and ids[new_item_value] then
      return nil
    end
    if new_item_name ~= item_name then
      ids = {}
      context = {
        ["digests"]={},
        ["media_urls"]={},
        ["video_files"]={},
        ["warc_digests"]={}
      }
      item_value = new_item_value
      item_type = new_item_type
      ids[item_value] = true
      abortgrab = false
      tries = 0
      retry_url = false
      item_name = new_item_name
      print("Archiving item " .. item_name)
    end
  end
end

allowed = function(url)
  local lower = string.lower(url)
  if string.match(lower, "^https?://ask%.ivideo%.sina%.com%.cn[/%?:]") then
    return false
  end
  if ids[lower] then
    return true
  end

  if context["media_urls"][lower] then
    return true
  end

  local found = find_item(url)
  if found then
    local new_item = found["type"] .. ":" .. found["value"]
    if found["type"] == "vid" and ids[found["value"]] then
      return true
    end
    if new_item ~= item_name then
      discover_item(discovered_items, percent_encode_url(new_item))
      return false
    end
    return true
  end

  if not (
    string.match(lower, "^https?://[^/]*iask%.com[/%?:]")
    or string.match(lower, "^https?://[^/]*sina%.cn[/%?:]")
    or string.match(lower, "^https?://[^/]*sina%.com[/%?:]")
    or string.match(lower, "^https?://[^/]*sina%.com%.cn[/%?:]")
    or string.match(lower, "^https?://[^/]*sina%.net[/%?:]")
    or string.match(lower, "^https?://[^/]*sina%.net%.cn[/%?:]")
    or string.match(lower, "^https?://[^/]*sinaapp%.com[/%?:]")
    or string.match(lower, "^https?://[^/]*sinacloud%.net[/%?:]")
    or string.match(lower, "^https?://[^/]*sincloud%.net[/%?:]")
    or string.match(lower, "^https?://[^/]*sinaedge%.com[/%?:]")
    or string.match(lower, "^https?://[^/]*sinaimg%.cn[/%?:]")
    or string.match(lower, "^https?://[^/]*sinajs%.cn[/%?:]")
    or string.match(lower, "^https?://[^/]*weibo%.cn[/%?:]")
    or string.match(lower, "^https?://[^/]*weibo%.com[/%?:]")
    or string.match(lower, "^https?://[^/]*weibo%.com%.cn[/%?:]")
    or string.match(lower, "^https?://[^/]*weibocdn%.com[/%?:]")
  ) then
    discover_item(discovered_outlinks, string.match(percent_encode_url(url), "^([^%s]+)"))
    return false
  end

  for _, pattern in pairs({
    "([0-9]+)",
    "comos%-([^/%?&;=:]+)",
    "([^/%?&;=:]+)"
  }) do
    for identifier in string.gmatch(url, pattern) do
      identifier = urlparse.unescape(identifier)
      if ids[string.lower(identifier)] then
        return true
      end
    end
  end

  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  return false
end

decode_codepoint = function(newurl)
  newurl = string.gsub(
    newurl, "\\[uU]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])",
    function(s)
      return utf8.char(tonumber(s, 16))
    end
  )
  return newurl
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil
  local json = nil

  downloaded[url] = true

  if abortgrab then
    return {}
  end

  local function fix_case(newurl)
    if not string.match(newurl, "^https?://[^/]") then
      return newurl
    end
    if string.match(newurl, "^https?://[^/]+$") then
      newurl = newurl .. "/"
    end
    local a, b = string.match(newurl, "^(https?://[^/]+/)(.*)$")
    return string.lower(a) .. b
  end

  local function check(newurl, headers)
    if not newurl then
      newurl = ""
    end
    newurl = html_entities.decode(decode_codepoint(newurl))
    newurl = string.gsub(newurl, "\\/", "/")
    newurl = string.match(newurl, "^%s*(.-)%s*$")
    newurl = fix_case(newurl)
    if not string.match(newurl, "^https?://") or string.match(newurl, "[%s\\]") then
      return nil
    end
    local url = string.match(newurl, "^([^#]+)")
    local url_ = url
    while string.match(url_, "&amp;") do
      url_ = string.gsub(url_, "&amp;", "&")
    end
    if not processed(url_) and allowed(url_) then
      table.insert(urls, {
        url=url_,
        headers=headers or {}
      })
      addedtolist[url_] = true
      addedtolist[url] = true
      return true
    end
  end

  local function force_check(newurl)
    if not check(newurl) and not processed(newurl) then
      ids[string.lower(newurl)] = true
      check(newurl)
    end
  end

  local function checknewurl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    if string.match(newurl, "^https?:////") then
      check(string.gsub(newurl, ":////", "://"))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^\\/\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (
      string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^data:")
      or string.match(newurl, "^irc:")
      or string.match(newurl, "^%${")
    ) then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function check_media(newurl)
    newurl = string.match(newurl, "^([^#]+)")
    context["media_urls"][string.lower(newurl)] = true
    check(newurl)
  end

  local function find_media(newurl)
    local file_id, extension = string.match(string.lower(newurl) .. "?", "/([0-9]+)%.([a-z0-9]+)%?")
    if extension == "flv"
      or extension == "hlv"
      or extension == "mp4" then
      return file_id, extension
    end
  end

  local function add_file(file_id, extension)
    file_id = tostring(file_id)
    if not string.match(file_id, "^[0-9]+$") then
      return nil
    end
    discover_item(discovered_items, "vid:" .. file_id)
    ids[file_id] = true
    if context["video_files"][file_id] == nil then
      context["video_files"][file_id] = false
    end
    check("https://s.video.sina.com.cn/video/getvideoidbyvid?vid=" .. file_id)
    check("https://api.ivideo.sina.com.cn/public/video/play/url?vid=" .. file_id .. "&appname=sinaplayer_pc&appver=V11220.210521.03&applt=web&tags=sinaplayer_pc")
    check_media("https://api.ivideo.sina.com.cn/public/video/play/url?vid=" .. file_id .. "&appname=sinaplayer_pc&appver=V11220.210521.03&applt=web&tags=sinaplayer_pc&direct=1")
    check_media("https://api.ivideo.sina.com.cn/v_play_ipad.php?vid=" .. file_id)
    check("https://video.sina.com.cn/interface/video_ids/video_ids.php?v=" .. file_id)
    check("https://interface.sina.cn/video/wap/videoinfo.d.json?vid=" .. file_id)
    check_media("https://newsapi.sina.cn/?resource=video/location&videoPlayUrl=" .. urlparse.escape("http://ask.ivideo.sina.com.cn/v_play_ipad.php?vid=" .. file_id))
    check("https://video.sina.com.cn/api/outPlayRefer.php/vid=" .. file_id .. "/s.swf")
    check("https://video.sina.com.cn/api/sinawebApi/outplayrefer.php/vid=" .. file_id .. "/s.swf")
    if extension == "flv" or extension == "hlv" or extension == "mp4" then
      for _, base_url in pairs({
        -- "https://sinacloud.net/s3.ivideo.sina.com.cn/",
        -- "https://cdn.sinacloud.net/edge.v.iask.com/",
        -- "https://sinacloud.net/edge.v.iask.com/",
        -- "https://cdn.sinacloud.net/edge.ivideo.sina.com.cn/",
        -- "https://sinacloud.net/edge.ivideo.sina.com.cn/",
        -- "http://s3.sinaapp.com/edge.v.iask.com/",
      }) do
        check_media(base_url .. file_id .. "." .. extension)
      end
    end
    for _, candidate in pairs({"flv", "hlv", "mp4"}) do
      check_media("https://s3.ivideo.sina.com.cn/" .. file_id .. "." .. candidate)
    end
  end

  local function check_page(newurl)
    newurl = string.match(newurl, "^([^#]+)")
    local original_url = newurl
    if string.match(newurl, "^http://video%.sina%.com%.cn/")
      or string.match(newurl, "^http://video%.sina%.cn/") then
      newurl = string.gsub(newurl, "^http://", "https://")
    end
    force_check(newurl)
    for _, page_url in pairs({original_url, newurl}) do
      if string.match(page_url, "^https?://video%.sina%.com%.cn/") then
        force_check("https://video.sina.com.cn/api/getVideoInfo.php?url=" .. urlparse.escape(page_url))
      elseif string.match(page_url, "^https?://video%.sina%.cn/") then
        force_check("https://interface.sina.cn/video/wap/get_videoinfo.d.json?url=" .. urlparse.escape(page_url))
      end
    end
    addedtolist[original_url] = true
  end

  local function scan_json(value, key, media_data, item_data)
    if type(value) == "table" then
      if media_data then
        add_file(value["file_id"], value["type"])
        add_file(value["vid"])
        add_file(value["ipad_vid"], "mp4")
        add_file(value["mp4vid"], "mp4")
      elseif value["video_id"] ~= nil then
        local video_id = tostring(value["video_id"])
        if string.match(video_id, "^[0-9]+$") then
          discover_item(discovered_items, "video:" .. video_id)
        end
      end
      for k, v in pairs(value) do
        scan_json(v, k, media_data, item_data)
      end
    elseif type(value) == "string" and string.match(value, "^https?://") then
      value = string.match(value, "^([^#]+)")
      if not media_data and not item_data then
        return nil
      end
      local lower = string.lower(value) .. "?"
      if string.match(lower, "count%.video%.sina%.com%.cn/")
        or string.match(lower, "sapi%.sina%.cn/statics/")
        or string.match(lower, "^https?://ask%.ivideo%.sina%.com%.cn/")
        or string.match(lower, "[/%.]beacon")
        or string.match(lower, "[/%.]log[/%.]") then
        return nil
      end
      local file_id, extension = find_media(value)
      if media_data then
        if file_id then
          add_file(file_id, extension)
          check_media(value)
          return nil
        elseif string.match(lower, "%.flv%?")
          or string.match(lower, "%.hlv%?")
          or string.match(lower, "%.mp4%?") then
          check_media(value)
          return nil
        end
      end
      if key == "avatar"
        or key == "face"
        or key == "profile_img"
        or key == "parent_profile_img"
        or key == "wb_profile_img" then
        return nil
      elseif (
          (
            type(key) == "string"
            and string.match(string.lower(key), "image")
          )
          or string.match(lower, "%.jpe?g%?")
          or string.match(lower, "%.png%?")
          or string.match(lower, "%.webp%?")
        ) then
        force_check(value)
      elseif (
          key == "video_url"
          or key == "playlink"
          or key == "docUrl"
        )
        and (
          string.match(lower, "^https?://video%.sina%.com%.cn/")
          or string.match(lower, "^https?://video%.sina%.cn/")
        ) then
        check_page(value)
      elseif not media_data and (
          key == "audio"
          or key == "video"
          or string.match(lower, "%.flv%?")
          or string.match(lower, "%.hlv%?")
          or string.match(lower, "%.mp4%?")
        ) then
        force_check(value)
      else
        check(value)
      end
    end
  end

  if allowed(url) and status_code < 300 then
    if string.match(url, "^https?://cmnt%.sina%.cn/aj/v2/list%?.-&group=0&thread=1&page=1&hot=1$") then
      json = cjson.decode(read_file(file))
      if json["status"] ~= 1 then
        error("Bad comment data.")
      end
      scan_json(json["data"], nil, false, true)
      return urls
    end
    if string.match(url, "^https?://comment5%.news%.sina%.com%.cn/page/info%?")
      or string.match(url, "^https?://cmnt%.sina%.cn/aj/v2/list%?") then
      json = cjson.decode(read_file(file))
      local result = json["result"]
      local news = result["news"]
      check_page(news["url"])
      local comment_base = string.match(url, "^(.+[?&]page=)[0-9]+")
      if comment_base then
        local show = tonumber(result["count"]["show"])
        for page = 1, math.ceil(show / 20) do
          if string.match(url, "^https?://cmnt%.sina%.cn/") then
            check(comment_base .. page)
          else
            check(comment_base .. page .. "&page_size=20")
          end
        end
      end
      scan_json(json, nil, false, true)
      return urls
    end
    if string.match(url, "^https?://s%.video%.sina%.com%.cn/video/play%?")
      or string.match(url, "^https?://s%.video%.sina%.com%.cn/video/h5play%?")
      or string.match(url, "^https?://interface%.sina%.cn/video/wap/videoinfo%.d%.json%?")
      or string.match(url, "^https?://interface%.sina%.cn/video/wap/get_videoinfo%.d%.json%?")
      or string.match(url, "^https?://video%.sina%.com%.cn/interface/video_ids/video_ids%.php%?")
      or string.match(url, "^https?://video%.sina%.com%.cn/api/getVideoInfo%.php%?")
      or string.match(url, "^https?://api%.ivideo%.sina%.com%.cn/public/video/play/url%?") then
      scan_json(cjson.decode(read_file(file)), nil, true)
      return urls
    end
    local video_metadata = string.match(url, "^https?://api%.ivideo%.sina%.com%.cn/public/video/info%?")
    local video_playback = string.match(url, "^https?://api%.ivideo%.sina%.com%.cn/public/video/play%?")
    if item_type == "vid"
      or string.match(url, "^https?://s%.video%.sina%.com%.cn/video/getvideoidbyvid%?")
      or video_metadata
      or video_playback then
      json = cjson.decode(read_file(file))
    elseif string.match(content_type, "^application/json")
      or string.match(content_type, "^text/html") then
      html = read_file(file)
      if string.match(html, "^%s*{") and string.match(html, "}%s*$") then
        json = cjson.decode(html)
        html = nil
      end
    end
    if item_type == "vid" or video_metadata or video_playback then
      if json["code"] == 0 then
        if item_type == "vid" or video_metadata then
          abort_item()
        end
        return urls
      elseif json["code"] ~= 1 then
        error("Bad video API data.")
      end
    end
    if item_type == "vid" then
      discover_item(discovered_items, "video:" .. json["data"]["video_id"])
      return urls
    end
    if video_metadata then
      if tostring(json["data"]["video_id"]) ~= item_value then
        error("Inconsistent video metadata.")
      end
      check("https://api.ivideo.sina.com.cn/public/video/play?video_id=" .. item_value .. "&appname=sinaplayer_pc&appver=V11220.210521.03&applt=web&tags=sinaplayer_pc&player=all")
      check("https://s.video.sina.com.cn/video/play?video_id=" .. item_value)
      check("https://s.video.sina.com.cn/video/h5play?video_id=" .. item_value)
      check("https://interface.sina.cn/video/wap/videoinfo.d.json?vid=" .. item_value)
      scan_json(json["data"], nil, true)
    elseif video_playback then
      if tostring(json["data"]["video_id"]) ~= item_value then
        error("Inconsistent video playback data.")
      end
      scan_json(json["data"], nil, true)
    elseif json then
      scan_json(json)
    end
    if context["media_urls"][string.lower(url)] then
      add_file(find_media(url))
    end
    if html then
      local decoded_html = string.gsub(html, "\\/", "/")
      for vid in string.gmatch(decoded_html, "[%s{,][\"']?vid[\"']?%s*:%s*[\"']?([0-9]+)") do
        discover_item(discovered_items, "vid:" .. vid)
      end
      for _, image_key in pairs({"mainPic", "thumbnailUrl"}) do
        for image_url in string.gmatch(decoded_html, '"' .. image_key .. '"%s*:%s*"([^"]+)"') do
          force_check(image_url)
        end
      end
      for video_info in string.gmatch(decoded_html, '"videoInfo"%s*:%s*{(.-)}') do
        local image_url = string.match(video_info, '"image"%s*:%s*"([^"]+)"')
        if image_url then
          force_check(image_url)
        end
        local play_url = string.match(video_info, '"playUrl"%s*:%s*"([^"]+)"')
        if play_url then
          check_media(play_url)
        end
      end
      if string.match(url, "^https?://video%.sina%.com%.cn/") then
        force_check("https://cre.mix.sina.com.cn/api/v3/get?offset=0&length=18&pageurl=" .. urlparse.escape(url) .. "&this_page=1&dedup=32&cre=videopagepc&mod=r&merge=3&statics=1&rfunc=105")
      end
      local channel = string.match(html, "channel%s*:%s*['\"]([^'\"]+)")
      local newsid = string.match(html, "newsid%s*:%s*['\"]([^'\"]+)")
        or string.match(html, "newsid%s*:%s*([0-9a-zA-Z:_%-]+)")
      if channel and newsid then
        ids[string.lower(string.match(newsid, "^comos%-(.+)$") or newsid)] = true
        check("https://comment5.news.sina.com.cn/page/info?version=1&format=json&channel=" .. channel .. "&newsid=" .. newsid .. "&group=0&compress=0&ie=utf-8&oe=utf-8&page=1&page_size=20")
        check("https://comment5.news.sina.com.cn/comment/skin/default.html?channel=" .. channel .. "&newsid=" .. newsid .. "&group=0")
      end
      local mobile_channel, mobile_newsid = string.match(decoded_html, "//cmnt%.sina%.cn/aj/v2/list%?channel=([^&\"']+)&newsid=([^&\"']+)")
      local comment_index = mobile_newsid and string.match(mobile_newsid, "^comos%-(.+)$")
      if comment_index then
        ids[string.lower(comment_index)] = true
        check("https://cmnt.sina.cn/index?product=comos&index=" .. comment_index .. "&tj_ch=video")
        check("https://cmnt.sina.cn/aj/v2/list?channel=" .. mobile_channel .. "&newsid=" .. mobile_newsid .. "&group=0&thread=1&page=1&hot=1")
        check("https://cmnt.sina.cn/aj/v2/list?channel=" .. mobile_channel .. "&newsid=" .. mobile_newsid .. "&group=group&thread=1&page=1")
        check("https://cmnt.sina.cn/aj/v2/counts?ids=" .. mobile_channel .. ":" .. mobile_newsid .. ":0")
      end
      check("https://api.ivideo.sina.com.cn/public/counter?appname=SinaVmsVideo&applt=web&appver=1.1&type=video&vpid=" .. item_value)
      for embed_url in string.gmatch(html, "swfOutsideUrl%s*:%s*['\"]([^'\"]+)") do
        check(urlparse.absolute(url, embed_url))
      end
      for newurl in string.gmatch(string.gsub(html, "&[qQ][uU][oO][tT];", '"'), '([^"]+)') do
        checknewurl(newurl)
      end
      for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
        checknewurl(newurl)
      end
      for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
        checknewshorturl(newurl)
      end
      for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
        checknewshorturl(newurl)
      end
      for newurl in string.gmatch(html, "[^%-]src='([^']+)'") do
        checknewshorturl(newurl)
      end
      for newurl in string.gmatch(html, '[^%-]src="([^"]+)"') do
        checknewshorturl(newurl)
      end
      for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
        checknewurl(string.gsub(newurl, "^[\"'](.-)[\"']$", "%1"))
      end
    end
  end

  return urls
end

wget.callbacks.dedup_response = function(url, digest)
  if context["digests"][url] then
    local checked = digest == context["digests"][url]
    context["digests"][url] = checked
    if checked then
      context["warc_digests"][digest] = true
    end
  end
end

wget.callbacks.write_to_warc = function(url, http_stat)
  local headers = http_stat["response_headers"]["headers"]
  status_code = http_stat["statcode"]
  content_type = headers["content-type"] and string.lower(headers["content-type"][1]) or ""
  set_item(url["url"])

  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
  io.stdout:flush()

  logged_response = true
  if not item_name then
    error("No item name found.")
  end

  local lower_url = string.lower(url["url"])
  if not (
    status_code == 200
    or (
      not (
        string.match(lower_url, "^https?://api%.ivideo%.sina%.com%.cn/public/video/info%?")
        or string.match(lower_url, "^https?://s%.video%.sina%.com%.cn/video/getvideoidbyvid%?")
      )
      and (
        (status_code >= 300 and status_code <= 399)
        or (
          status_code == 400
          and string.match(lower_url, "^https?://api%.ivideo%.sina%.com%.cn/public/video/play%?")
        )
        or status_code == 404
      )
    )
  ) then
    retry_url = true
    return false
  end
  if http_stat["len"] == 0
    and status_code == 200
    and not string.match(lower_url .. "?", "^https?://video%.sina%.com%.cn/share/video/[0-9]+%.swf%?") then
    retry_url = true
    return false
  end
  if context["media_urls"][lower_url]
    and status_code == 200
    and not string.match(content_type, "^application/json")
    and not string.match(content_type, "^text/") then
    if headers["x-filesize"] and http_stat["len"] ~= tonumber(headers["x-filesize"][1]) then
      retry_url = true
      return false
    end
    local expected = nil
    if headers["x-filesize"] and headers["etag"] then
      expected = string.match(headers["etag"][1], "^\"([0-9a-fA-F]+)\"$")
    end
    local sha1 = openssl_digest.new("sha1")
    local md5 = nil
    if expected and string.len(expected) == 32 then
      md5 = openssl_digest.new("md5")
    end
    local file = assert(io.open(http_stat["local_file"], "rb"))
    while true do
      local data = file:read(16 * 1024 * 1024)
      if not data then
        break
      end
      sha1:update(data)
      if md5 then
        md5:update(data)
      end
    end
    file:close()
    if md5 and basexx.to_hex(md5:final()) ~= string.upper(expected) then
      error("File does not match etag.")
    end
    context["digests"][url["url"]] = "sha1:" .. basexx.to_base32(sha1:final())
    local video_file_id, extension = string.match(lower_url, "^https://s3%.ivideo%.sina%.com%.cn/([0-9]+)%.([a-z0-9]+)$")
    if video_file_id and (extension == "flv" or extension == "hlv" or extension == "mp4") then
      context["video_files"][video_file_id] = true
    end
  end
  if abortgrab then
    print("Not writing to WARC.")
    return false
  end
  retry_url = false
  tries = 0
  return true
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]

  if not logged_response then
    url_count = url_count + 1
    io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
    io.stdout:flush()
  end
  logged_response = false

  if killgrab then
    return wget.actions.ABORT
  end

  set_item(url["url"])
  if not item_name then
    error("No item name found.")
  end

  if abortgrab then
    abort_item()
    return wget.actions.EXIT
  end

  local lower_url = string.lower(url["url"])
  local newloc = nil
  if status_code >= 300 and status_code <= 399 and not retry_url then
    if http_stat["newloc"] then
      newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    end
    if newloc then
      local lower_newloc = string.lower(newloc)
      if context["media_urls"][lower_url] then
        context["media_urls"][lower_newloc] = true
      elseif ids[lower_url] then
        ids[lower_newloc] = true
      end
    end
    if not newloc then
      retry_url = true
    elseif processed(newloc) or not allowed(newloc) then
      tries = 0
      return wget.actions.EXIT
    end
  end

  if status_code == 0 or retry_url then
    io.stdout:write("Server returned bad response. ")
    io.stdout:flush()
    tries = tries + 1
    local maxtries = 5
    if tries > maxtries then
      io.stdout:write(" Skipping.\n")
      io.stdout:flush()
      tries = 0
      abort_item()
      return wget.actions.EXIT
    end
    local sleep_time = math.random(
      math.floor(math.pow(2, tries-0.5)),
      math.floor(math.pow(2, tries))
    )
    io.stdout:write("Sleeping " .. sleep_time .. " seconds.\n")
    io.stdout:flush()
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  else
    downloaded[url["url"]] = true
  end

  if newloc and processed(newloc) then
    tries = 0
    return wget.actions.EXIT
  end

  tries = 0

  return wget.actions.NOTHING
end

wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  for _, checked in pairs(context["digests"]) do
    if checked ~= true and not context["warc_digests"][checked] then
      error("WARC digest does not match downloaded data.")
    end
  end
  if item_type == "video" then
    if next(context["video_files"]) == nil then
      abort_item()
    end
    for file_id, archived in pairs(context["video_files"]) do
      if not archived then
        error("No video archived for vid " .. file_id .. ".")
      end
    end
  end

  local function submit_backfeed(items, key)
    local tries = 0
    local maxtries = 5
    while tries < maxtries do
      if killgrab then
        return false
      end
      local body, code, headers, status = https.request(
        "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
        items .. "\0"
      )
      if code == 200 and body ~= nil and cjson.decode(body)["status_code"] == 200 then
        io.stdout:write(string.match(body, "^(.-)%s*$") .. "\n")
        io.stdout:flush()
        return nil
      end
      io.stdout:write("Failed to submit discovered URLs." .. tostring(code) .. tostring(body) .. "\n")
      io.stdout:flush()
      os.execute("sleep " .. math.floor(math.pow(2, tries)))
      tries = tries + 1
    end
    kill_grab()
    error()
  end

  local file = io.open(item_dir .. "/" .. warc_file_base .. "_bad-items.txt", "w")
  for url, _ in pairs(bad_items) do
    file:write(url .. "\n")
  end
  file:close()
  for key, data in pairs({
    ["sinavideo-4xm1495fhdoztgvi"] = discovered_items,
    ["urls-argjgz5xgat69puw"] = discovered_outlinks
  }) do
    print("queuing for", string.match(key, "^(.+)%-"))
    local items = nil
    local count = 0
    for item, _ in pairs(data) do
      print("found item", item)
      if items == nil then
        items = item
      else
        items = items .. "\0" .. item
      end
      count = count + 1
      if count == 1000 then
        submit_backfeed(items, key)
        items = nil
        count = 0
      end
    end
    if items ~= nil then
      submit_backfeed(items, key)
    end
  end
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if killgrab then
    return wget.exits.IO_FAIL
  end
  if abortgrab then
    abort_item()
  end
  return exit_status
end
