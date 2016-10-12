
--local aws_auth = require "resty.aws_auth"
local prepare_request = require "kong.plugins.aws-lambda.v4".prepare_request

local http = require "resty.http"
local cjson = require "cjson"

local ngx_log = ngx.log

local _M = {}


function _M.execute(conf)

  local bodyJson = cjson.encode({
    key1 = "some_value1",
    key2 = "some_value2",
    key3 = "some_value3"
  })

  local host = string.format("lambda.%s.amazonaws.com", conf.aws_region)
  local path = string.format("/2015-03-31/functions/%s/invocations", 
                            conf.function_name)

  local opts = {
    Region = conf.aws_region,
    Service = "lambda",
    method = "POST",
    headers = {
      ["X-Amz-Target"] = "invoke",
      ["Content-Type"] = "application/x-amz-json-1.1",
      ["Content-Length"] = tostring(string.len(bodyJson))
    },
    body = bodyJson, 
    path = path,
    AccessKey = conf.aws_key,
    SecretKey = conf.aws_secret,
    query = conf.qualifier and "Qualifier="..conf.qualifier
  }

  local request, _ = prepare_request(opts)

  
  local client = http.new()
  client:connect(host, 443)
  client:set_timeout(60000)
  local ok, err = client:ssl_handshake()
  if not ok then
    ngx_log(ngx.ERR, err)
    return
  end

  local res, err = client:request {
    method = "POST",
    path = request.url,
    body = request.body,
    headers = request.headers
  }

  if not res then
    ngx_log(ngx.ERR, err)
    return
  end

  print(res:read_body())

end

--[[
function _M.execute(conf)
  -- Calculate Lambda host
  local host = string.format("lambda.%s.amazonaws.com", conf.aws_region)

  -- TODO: Remove
  local body = {
    key1 = "some_value1",
    key2 = "some_value2",
    key3 = "some_value3"
  }

  -- Create AWS Signature
  local config  = {
    aws_host  = host,
    aws_key = conf.aws_key,
    aws_secret = conf.aws_secret,
    aws_region = conf.aws_region,
    aws_service = "lambda",
    request_body = {} --body
  }
  local aws = aws_auth:new(config)
  local auth = aws:get_authorization_header() -- "authorization" header value
  local amz_date = aws:get_date_header() -- "x-amz-date" header value


  print(aws:get_canonical_header())
  print(aws:get_date_header())

  -- Make request to Lambda
  local client = http.new()
  client:connect(host, 443)
  client:set_timeout(60000)
  local ok, err = client:ssl_handshake()
  if not ok then
    ngx_log(ngx.ERR, err)
    return
  end

  local url = string.format("/2015-03-31/functions/%s/invocations%s", 
                            conf.function_name, 
                            conf.qualifier and "?Qualifier="..conf.qualifier or "")

  local res, err = client:request {
    method = "POST",
    path = url,
    --body = cjson.encode(body),
    headers = {
      ["Authorization"] = auth,
      ["X-Amz-Date"] = amz_date,
      --["X-Amz-Invocation-Type"] = conf.invocation_type,
      --["Content-Type"] = "application/json"
    }
  }

  if not res then
    ngx_log(ngx.ERR, err)
    return
  end

  print(res:read_body())

  --print(require("inspect")(res))
end
--]]

return _M
