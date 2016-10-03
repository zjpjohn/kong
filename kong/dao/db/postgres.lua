local pgmoon = require "pgmoon-mashape"
local Errors = require "kong.dao.errors"
local utils = require "kong.tools.utils"
local uuid = utils.uuid

local TTL_CLEANUP_INTERVAL = 60 -- 1 minute

local _M = require("kong.dao.db").new_db("postgres")

_M.dao_insert_values = {
  id = function()
    return uuid()
  end
}

_M.additional_tables = {"ttls"}

function _M.new(kong_config)
  local self = _M.super.new()

  self.query_options = {
    host = kong_config.pg_host,
    port = kong_config.pg_port,
    user = kong_config.pg_user,
    password = kong_config.pg_password,
    database = kong_config.pg_database,
    ssl = kong_config.pg_ssl,
    ssl_verify = kong_config.pg_ssl_verify,
    cafile = kong_config.lua_ssl_trusted_certificate
  }

  return self
end

-- TTL clean up timer functions

local function do_clean_ttl(premature, postgres)
  if premature then return end

  local ok, err = postgres:clear_expired_ttl()
  if not ok then
    ngx.log(ngx.ERR, "failed to cleanup TTLs: ", err)
  end
  local ok, err = ngx.timer.at(TTL_CLEANUP_INTERVAL, do_clean_ttl, postgres)
  if not ok then
    ngx.log(ngx.ERR, "failed to create timer: ", err)
  end
end

function _M:start_ttl_timer()
  if ngx then
    local ok, err = ngx.timer.at(TTL_CLEANUP_INTERVAL, do_clean_ttl, self)
    if not ok then
      ngx.log(ngx.ERR, "failed to create timer: ", err)
    end
    self.timer_started = true
  end
end

function _M:init_worker()
  self:start_ttl_timer()
end

function _M:infos()
  return {
    desc = "database",
    name = self:clone_query_options().database
  }
end

-- Formatting

-- @see pgmoon
local function escape_identifier(ident)
  return '"'..(tostring(ident):gsub('"', '""'))..'"'
end

-- @see pgmoon
local function escape_literal(val, field)
  local t_val = type(val)
  if t_val == "number" then
    return tostring(val)
  elseif t_val == "string" then
    return "'"..tostring((val:gsub("'", "''"))).."'"
  elseif t_val == "boolean" then
    return val and "TRUE" or "FALSE"
  elseif t_val == "table" and field and (field.type == "table" or field.type == "array") then
    local json = require "cjson"
    return escape_literal(json.encode(val))
  end
  error("don't know how to escape value: "..tostring(val))
end

local function get_where(tbl)
  local where = {}

  for col, value in pairs(tbl) do
    where[#where + 1] = string.format("%s = %s",
                        escape_identifier(col),
                        escape_literal(value))
  end

  return table.concat(where, " AND ")
end

local function parse_error(err_str)
  local err
  if string.find(err_str, "Key .* already exists") then
    local col, value = string.match(err_str, "%((.+)%)=%((.+)%)")
    if col then
      err = Errors.unique {[col] = value}
    end
  elseif string.find(err_str, "violates foreign key constraint") then
    local col, value = string.match(err_str, "%((.+)%)=%((.+)%)")
    if col then
      err = Errors.foreign {[col] = value}
    end
  end

  return err or Errors.db(err_str)
end

local function get_select_fields(schema)
  local fields = {}
  local timestamp_fields = {}
  for k, v in pairs(schema.fields) do
    if v.type == "timestamp" then
      table.insert(timestamp_fields, string.format("extract(epoch from %s)::bigint*1000 as %s", k, k))
    else
      table.insert(fields, "\""..k.."\"")
    end
  end
  return table.concat(fields, ",")..(#timestamp_fields > 0 and ","..table.concat(timestamp_fields, ",") or "")
end

-- Querying

function _M:query(query, schema)
  local conn_opts = self:clone_query_options()
  local pg = pgmoon.new(conn_opts)
  local ok, err = pg:connect()
  if not ok then
    return nil, Errors.db(err)
  end

  local res, err = pg:query(query)
  if ngx and ngx.get_phase() ~= "init" then
    pg:keepalive()
  else
    pg:disconnect()
  end

  if res == nil then
    return nil, parse_error(err)
  elseif schema ~= nil then
    self:deserialize_rows(res, schema)
  end

  return res
end

function _M:retrieve_primary_key_type(schema, table_name)
  if schema.primary_key and #schema.primary_key == 1 then
    if not self.column_types then self.column_types = {} end

    local result = self.column_types[table_name]
    if not result then
      local query = string.format("SELECT data_type FROM information_schema.columns WHERE table_name = '%s' and column_name = '%s' LIMIT 1",
                    table_name, schema.primary_key[1])
      local res, err = self:query(query)
      if err then
        return nil, err
      elseif #res > 0 then
        result = res[1].data_type
        self.column_types[table_name] = result
      end
    end

    return result
  end
end

function _M:get_select_query(select_clause, schema, table, where, offset, limit)
  local query

  local join_ttl = schema.primary_key and #schema.primary_key == 1
  if join_ttl then
    local primary_key_type = self:retrieve_primary_key_type(schema, table)
    query = string.format([[SELECT %s FROM %s LEFT OUTER JOIN ttls ON (%s.%s = ttls.primary_%s_value) WHERE
    (ttls.primary_key_value IS NULL OR (ttls.table_name = '%s' AND expire_at > CURRENT_TIMESTAMP(0) at time zone 'utc'))]],
            select_clause, table, table, schema.primary_key[1], primary_key_type == "uuid" and "uuid" or "key", table)
  else
    query = string.format("SELECT %s FROM %s", select_clause, table)
  end

  if where ~= nil then
    query = query..(join_ttl and " AND " or " WHERE ")..where
  end
  if limit ~= nil then
    query = query.." LIMIT "..limit
  end
  if offset ~= nil and offset > 0 then
    query = query.." OFFSET "..offset
  end
  return query
end

function _M:deserialize_rows(rows, schema)
  if schema then
    local json = require "cjson"
    for i, row in ipairs(rows) do
      for col, value in pairs(row) do
        if type(value) == "string" and schema.fields[col] and
          (schema.fields[col].type == "table" or schema.fields[col].type == "array") then
          rows[i][col] = json.decode(value)
        end
      end
    end
  end
end

function _M:deserialize_timestamps(row, schema)
  local result = row
  for k, v in pairs(schema.fields) do
    if v.type == "timestamp" and result[k] then
      local query = string.format("SELECT extract(epoch from timestamp '%s')::bigint*1000 as %s;", result[k], k)
      local res, err = self:query(query)
      if err then
        return nil, err
      elseif #res > 0 then
        result[k] = res[1][k]
      end
    end
  end
  return result
end

function _M:serialize_timestamps(tbl, schema)
  local result = tbl
  for k, v in pairs(schema.fields) do
    if v.type == "timestamp" and result[k] then
      local query = string.format("SELECT to_timestamp(%d/1000) at time zone 'UTC' as %s;", result[k], k)
      local res, err = self:query(query)
      if err then
        return nil, err
      elseif #res > 0 then
        result[k] = res[1][k]
      end
    end
  end
  return result
end

function _M:ttl(tbl, table_name, schema, ttl)
  if not schema.primary_key or #schema.primary_key ~= 1 then
    return false, "Cannot set a TTL if the entity has no primary key, or has more than one primary key"
  end

  local primary_key_type = self:retrieve_primary_key_type(schema, table_name)

  -- Get current server time
  local query = "SELECT extract(epoch from now() at time zone 'utc')::bigint*1000 as timestamp;"
  local res, err = self:query(query)
  if err then
    return false, err
  end

  -- The expiration is always based on the current time
  local expire_at = res[1].timestamp + (ttl * 1000)

  local query = string.format("SELECT upsert_ttl('%s', %s, '%s', '%s', to_timestamp(%d/1000) at time zone 'UTC')",
                              tbl[schema.primary_key[1]], primary_key_type == "uuid" and "'"..tbl[schema.primary_key[1]].."'" or "NULL",
                              schema.primary_key[1], table_name, expire_at)
  local _, err = self:query(query)
  if err then
    return false, err
  end
  return true
end

-- Delete old expired TTL entities
function _M:clear_expired_ttl()
  local query = "SELECT * FROM ttls WHERE expire_at < CURRENT_TIMESTAMP(0) at time zone 'utc'"
  local res, err = self:query(query)
  if err then
    return false, err
  end

  for _, v in ipairs(res) do
    local delete_entity_query = string.format("DELETE FROM %s WHERE %s='%s'", v.table_name, v.primary_key_name, v.primary_key_value)
    local _, err = self:query(delete_entity_query)
    if err then
      return false, err
    end
    local delete_ttl_query = string.format("DELETE FROM ttls WHERE primary_key_value='%s' AND table_name='%s'", v.primary_key_value, v.table_name)
    local _, err = self:query(delete_ttl_query)
    if err then
      return false, err
    end
  end

  return true
end

function _M:insert(table_name, schema, model, _, options)
  local values, err = self:serialize_timestamps(model, schema)
  if err then
    return nil, err
  end

  local cols, args = {}, {}
  for col, value in pairs(values) do
    cols[#cols + 1] = escape_identifier(col)
    args[#args + 1] = escape_literal(value, schema.fields[col])
  end

  cols = table.concat(cols, ", ")
  args = table.concat(args, ", ")

  local query = string.format("INSERT INTO %s(%s) VALUES(%s) RETURNING *",
                              table_name, cols, args)
  local res, err = self:query(query, schema)
  if err then
    return nil, err
  elseif #res > 0 then
    local res, err = self:deserialize_timestamps(res[1], schema)
    if err then
      return nil, err
    else
      -- Handle options
      if options and options.ttl then
        local _, err = self:ttl(res, table_name, schema, options.ttl)
        if err then
          return nil, err
        end
      end
      return res
    end
  end
end

function _M:find(table_name, schema, primary_keys)
  local where = get_where(primary_keys)
  local query = self:get_select_query(get_select_fields(schema), schema, table_name, where)
  local rows, err = self:query(query, schema)
  if err then
    return nil, err
  elseif rows and #rows > 0 then
    return rows[1]
  end
end

function _M:find_all(table_name, tbl, schema)
  local where
  if tbl ~= nil then
    where = get_where(tbl)
  end

  local query = self:get_select_query(get_select_fields(schema), schema, table_name, where)
  return self:query(query, schema)
end

function _M:find_page(table_name, tbl, page, page_size, schema)
  if page == nil then
    page = 1
  end

  local total_count, err = self:count(table_name, tbl, schema)
  if err then
    return nil, err
  end

  local total_pages = math.ceil(total_count/page_size)
  local offset = page_size * (page - 1)

  local where
  if tbl ~= nil then
    where = get_where(tbl)
  end

  local query = self:get_select_query(get_select_fields(schema), schema, table_name, where, offset, page_size)
  local rows, err = self:query(query, schema)
  if err then
    return nil, err
  end

  local next_page = page + 1
  return rows, nil, (next_page <= total_pages and next_page or nil)
end

function _M:count(table_name, tbl, schema)
  local where
  if tbl ~= nil then
    where = get_where(tbl)
  end

  local query = self:get_select_query("COUNT(*)", schema, table_name, where)
  local res, err = self:query(query)
  if err then
    return nil, err
  elseif res and #res > 0 then
    return res[1].count
  end
end

function _M:update(table_name, schema, _, filter_keys, values, nils, full, _, options)
  local args = {}
  local values, err = self:serialize_timestamps(values, schema)
  if err then
    return nil, err
  end
  for col, value in pairs(values) do
    args[#args + 1] = string.format("%s = %s",
                      escape_identifier(col), escape_literal(value, schema.fields[col]))
  end

  if full then
    for col in pairs(nils) do
      args[#args + 1] = escape_identifier(col).." = NULL"
    end
  end

  args = table.concat(args, ", ")

  local where = get_where(filter_keys)
  local query = string.format("UPDATE %s SET %s WHERE %s RETURNING *",
                              table_name, args, where)
  local res, err = self:query(query, schema)
  if err then
    return nil, err
  elseif res and res.affected_rows == 1 then
    local res, err = self:deserialize_timestamps(res[1], schema)
    if err then
      return nil, err
    else
      -- Handle options
      if options and options.ttl then
        local _, err = self:ttl(res, table_name, schema, options.ttl)
        if err then
          return nil, err
        end
      end
      return res
    end
  end
end

function _M:delete(table_name, schema, primary_keys)
  local where = get_where(primary_keys)
  local query = string.format("DELETE FROM %s WHERE %s RETURNING *",
                              table_name, where)
  local res, err = self:query(query, schema)
  if err then
    return nil, err
  end

  if res and res.affected_rows == 1 then
    return self:deserialize_timestamps(res[1], schema)
  end
end

-- Migrations

function _M:queries(queries)
  if utils.strip(queries) ~= "" then
    local res, err = self:query(queries)
    if not res then return err end
  end
end

function _M:drop_table(table_name)
  local res, err = self:query("DROP TABLE "..table_name.." CASCADE")
  if not res then return nil, err end
  return true
end

function _M:truncate_table(table_name)
  local res, err = self:query("TRUNCATE "..table_name.." CASCADE")
  if not res then return nil, err end
  return true
end

function _M:current_migrations()
  -- Check if schema_migrations table exists
  local rows, err = self:query "SELECT to_regclass('schema_migrations')"
  if err then
    return nil, err
  end

  if #rows > 0 and rows[1].to_regclass == "schema_migrations" then
    return self:query "SELECT * FROM schema_migrations"
  else
    return {}
  end
end

function _M:record_migration(id, name)
  local res, err = self:query{
    [[
      CREATE OR REPLACE FUNCTION upsert_schema_migrations(identifier text, migration_name varchar) RETURNS VOID AS $$
      DECLARE
      BEGIN
          UPDATE schema_migrations SET migrations = array_append(migrations, migration_name) WHERE id = identifier;
          IF NOT FOUND THEN
          INSERT INTO schema_migrations(id, migrations) VALUES(identifier, ARRAY[migration_name]);
          END IF;
      END;
      $$ LANGUAGE 'plpgsql';
    ]],
    string.format("SELECT upsert_schema_migrations('%s', %s)", id, escape_literal(name))
  }
  if not res then return nil, err end
  return true
end

return _M
