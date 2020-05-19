-- TODO
-- etcd_client implementation
-- lock_delay location
-- connection status
-- set_leaders duplicates


local fiber = require('fiber')
local checks = require('checks')
local errors = require('errors')
local netbox = require('net.box')
local json = require('json')
local fio = require('fio')
local uuid = require('uuid')

local etcd = require('cartridge.etcd') -- TODO etcd_client implementation
local etcd_client = etcd:new{}
etcd_client:discovery()

local ClientError  = errors.new_class('ClientError')
local SessionError = errors.new_class('SessionError')
local EtcdError = errors.new_class('EtcdError')

local INDEX_POISON = 1

local function acquire_lock(session, lock_args)
    checks('etcd_session', 'table')

    if session.id == nil then
        return nil, SessionError:new('Session is dropped')
    end

    local lock_data = json.encode({uuid = lock_args[1], uri = lock_args[2], session_id = session.id})
    local request_body = {
            value = lock_data,
            ttl = session.lock_delay
        }

    if session.lock_acquired then
        request_body.prevValue = lock_data
    else
        request_body.prevExist = false
    end

    local lock = etcd_client:request('PUT', session.prefix..'/lock', request_body)
    if lock.errorCode ~= nil then
        if session.lock_acquired == true then
            -- probably lock was stolen
            session.lock_acquired = false
            return nil, SessionError:new('The lock was stolen')
        else
            -- probably lock is taken
            session.lock_acquired = false
            return false
        end
    end

    local leaders = etcd_client:request('GET', session.prefix..'/leaders', {})
    if leaders.errorCode ~= nil and leaders.errorCode ~= 100 then
        session.lock_acquired = false
        return nil, SessionError:new(leaders.message)
    end

    local leaders_data
    if leaders.errorCode == 100 then
        leaders_data = json.encode{}
    else
        leaders_data = leaders.node.value
    end

    leaders = etcd_client:request('PUT', session.prefix..'/leaders', {value=leaders_data})
    if leaders.errorCode ~= nil then
        return nil, SessionError:new(leaders.message)
    end

    session.leaders = json.decode(leaders.node.value)
    session.index = leaders.node.modifiedIndex
    session.uuid = lock_args[1]
    session.uri = lock_args[2]
    session.lock_acquired = true
    return true
end

local function get_lock_delay(session) --TODO lock_delay
    if session.id == nil then
        return nil, SessionError:new('Session is dropped')
    end
    return session.lock_delay
end

local function set_leaders(session, updates) --TODO /keys/leaders/${replicaset_uuid} leader_uuid
    checks('etcd_session', 'table')

    if session.id == nil then
        return nil, SessionError:new('Session is dropped')
    end

    if session.lock_acquired == false then
        return nil, SessionError:new('You are not holding the lock')
    end

    local new_leaders = {}
    for _, leader in ipairs(updates) do
        local replicaset_uuid, instance_uuid = unpack(leader)
        if new_leaders[replicaset_uuid] ~= nil then
            return nil, ClientError:new('Duplicate key in updates')
        end

        new_leaders[replicaset_uuid] = instance_uuid or session.leaders[replicaset_uuid]

    end
    new_leaders = json.encode(new_leaders)

    local leaders = etcd_client:request('PUT', session.prefix..'/leaders', {value=new_leaders, prevIndex=session.index})
    if leaders.errorCode ~= nil then
        return nil, SessionError:new('You are not holding the lock')
    end

    session.leaders = json.decode(leaders.node.value)
    session.index = leaders.node.modifiedIndex

    return true
end

local function get_leaders(session) -- TODO longpoll leaders, error handling
    checks('etcd_session')

    if session.id == nil then
        return nil, SessionError:new('Session is dropped')
    end

    if session.lock_acquired then
        return session.leaders
    end

    local leaders = etcd_client:request('GET', session.prefix..'/leaders', {})
    session.leaders = json.decode(leaders.node.value)
    session.index = leaders.node.modifiedIndex

    return session.leaders
end

local function get_coordinator(session)
    checks('etcd_session')

    if session.id == nil then
        return nil
    end

    local lock = etcd_client:request('GET', session.prefix..'/lock', {})

    if lock.errorCode ~= nil then
        if lock.errorCode == 100 then
            -- there is no coordinator
            return nil
        end
        return nil, SessionError:new(lock.message)
    end

    local ret = json.decode(lock.node.value)
    ret.session_id = nil

    return ret

end

local function is_locked(session)
    return session.lock_acquired
end

local function is_alive(session)
    checks('etcd_session')

    if session.id == nil then
        return false
    end

    return true
end

local function is_connected(session)
    checks('etcd_session')

    if session.id == nil then
        return false
    end

    return true
end

local function drop(session)
    checks('etcd_session')

    session.lock_acquired = false
    local lock_data = {uuid = session.uuid, uri = session.uri, session_id = session.id}
    if session.uri ~= nil and session.uuid ~= nil then
        local resp = etcd_client:request('DELETE', session.prefix..'/lock',{prevValue = json.encode(lock_data)})

        if resp.errorCode ~= nil then
            -- lock in another session
            return false
        end

        session.uri = nil
        session.uuid = nil
        session.id = nil
        return true
    else
        return true -- if lock is stolen, session is dropped?
    end
end

local session_mt = {
    __type = 'etcd_session',
    __index = {
        is_alive = is_alive,
        is_locked = is_locked,
        is_connected = is_connected,
        acquire_lock = acquire_lock,
        set_leaders = set_leaders,
        get_leaders = get_leaders,
        get_lock_delay = get_lock_delay,
        get_coordinator = get_coordinator,
        drop = drop,
    },
}

local function get_session(client)
    checks('etcd_client')

    if client.session ~= nil then
        return client.session
    end

    local session = {
        lock_acquired = false,
        call_timeout = client.call_timeout,
        lock_delay = client.lock_delay,
        id = uuid.str(),
        prefix = client.prefix,
        index = INDEX_POISON -- TODO 1 is not reliable
    }
    client.session = setmetatable(session, session_mt)
    return client.session
end

local function drop_session(client)
    checks('etcd_client')
    if client.session ~= nil then
        client.session:drop()
        client.session = nil
    end
end

local function longpoll(client, timeout)
    checks('etcd_client', 'number')

    local session = client:get_session()
    if session.index == INDEX_POISON then
        return session:get_leaders()
    end

    local leaders = etcd_client:request('GET', session.prefix..'/leaders',
        {
            wait = true,
            timeout = timeout,
            waitIndex = session.index + 1
        })
    if leaders.errorCode ~= nil then
        return nil, ClientError:new(leaders.message)
    end
    session.index = leaders.node.modifiedIndex

    return json.decode(leaders.node.value)

end

local client_mt = {
    __type = 'etcd_client',
    __index = {
        longpoll = longpoll,
        get_session = get_session,
        drop_session = drop_session,
    },
}

local function new(opts)
    checks({
        uri = 'string',
        password = 'string',
        call_timeout = 'number',
        lock_delay = 'number', -- TODO lock_delay's fate
        prefix = 'string'
    })

    local client = {
        state_provider = 'tarantool',
        session = nil,
        uri = opts.uri,
        password = opts.password,
        lock_delay = opts.lock_delay, --TODO lock_delay's fate
        call_timeout = opts.call_timeout,
        prefix = opts.prefix
    }
    return setmetatable(client, client_mt)
end


return {
    new = new,
}


-- TODO

-- /prefix/lock -> {uuid, uri, session_id} (CAS prevExist)
-- /prefix/leaders -> {replicaset_uuid: leader_uuid}
