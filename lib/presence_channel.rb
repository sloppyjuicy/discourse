# frozen_string_literal: true

class PresenceChannel

  DEFAULT_TIMEOUT ||= 60

  attr_reader :name, :timeout, :message_bus_channel_name

  def initialize(name, timeout: nil)
    @name = name
    @timeout = timeout || DEFAULT_TIMEOUT
    @message_bus_channel_name = "/presence/#{name}"
  end

  def enter(user_id:, client_id: nil)
    Discourse.redis.eval(
      ENTER_LUA,
      redis_keys,
      [user_id, client_id, timeout]
    )

    message = {
      "type" => "enter",
      "user_id" => user_id,
    }

    MessageBus.publish(message_bus_channel_name, message)

    auto_leave
  end

  def leave(user_id:, client_id: nil)
    Discourse.redis.eval(
      LEAVE_LUA,
      redis_keys,
      [user_id, client_id]
    )

    auto_leave
  end

  def user_ids
    auto_leave

    Discourse.redis.eval(
      USER_IDS_LUA,
      redis_keys,
    )
  end

  def count
    auto_leave

    Discourse.redis.eval(
      COUNT_LUA,
      redis_keys,
      [Time.zone.now.to_i]
    )
  end

  def auto_leave
    left_user_ids = Discourse.redis.eval(
      AUTO_LEAVE_LUA,
      redis_keys,
      [Time.zone.now.to_i]
    )

    left_user_ids.each do |user_id|
      message = {
        "type" => "leave",
        "user_id" => user_id,
      }

      MessageBus.publish(message_bus_channel_name, message)
    end

  end

  def clear
    Discourse.redis.without_namespace.del(redis_key_zlist)
    Discourse.redis.without_namespace.del(redis_key_hash)
  end

  private

  def local_time
    PresenceChannel.use_system_time ? Time.zone.now.to_i : nil
  end

  def redis_keys
    [redis_key_zlist, redis_key_hash]
  end

  def redis_key_zlist
    Discourse.redis.namespace_key("_presence_#{name}_zlist")
  end

  def redis_key_hash
    Discourse.redis.namespace_key("_presence_#{name}_hash")
  end

  PARAMS_LUA = <<~LUA
    local user_id = ARGV[1]
    local client_id = ARGV[2]
    local timeout = ARGV[3]

    local zlist_key = KEYS[1]
    local hash_key = KEYS[2]
  LUA

  ENTER_LUA = <<~LUA
    #{PARAMS_LUA}

    local now_raw = redis.call('TIME')
    local now = tonumber(now_raw[1])

    local zlist_elem = tostring(user_id) .. " " .. tostring(client_id)

    redis.call('ZADD', zlist_key, now + timeout, zlist_elem)
    redis.call('HINCRBY', hash_key, tostring(user_id), 1)
  LUA

  LEAVE_LUA = <<~LUA
    #{PARAMS_LUA}

    local zlist_elem = tostring(user_id) .. " " .. tostring(client_id)

    local position = tonumber(redis.call('ZREM', zlist_key, zlist_elem))

    if tonumber(position) > 0 then
      local val = redis.call('HINCRBY', hash_key, user_id, -1)
      if val <= 0 then
        redis.call('HDEL', hash_key, user_id)
      end
    end
  LUA

  USER_IDS_LUA = <<~LUA
    local zlist_key = KEYS[1]
    local hash_key = KEYS[2]

    local user_ids = redis.call('HKEYS', hash_key)
    table.foreach(user_ids, function(k,v) user_ids[k] = tonumber(v) end)

    return user_ids
  LUA

  COUNT_LUA = <<~LUA
    local zlist_key = KEYS[1]
    local hash_key = KEYS[2]

    local time = ARGV[1]

    return redis.call('HLEN', hash_key)
  LUA

  AUTO_LEAVE_LUA = <<~LUA
    local zlist_key = KEYS[1]
    local hash_key = KEYS[2]
    local time = ARGV[1]

    local expire = redis.call('ZRANGE', zlist_key, 0, time, 'BYSCORE')

    local expired_user_ids = {}

    local expireOld = function(k, v)
      local user_id = v:match("[^ ]+")
      local val = redis.call('HINCRBY', hash_key, user_id, -1)
      if val <= 0 then
        table.insert(expired_user_ids, tonumber(user_id))
        redis.call('HDEL', hash_key, user_id)
      end
    end

    table.foreach(expire, expireOld)

    redis.call('ZREMRANGEBYSCORE', zlist_key, "-inf", time)

    return expired_user_ids
  LUA

end
