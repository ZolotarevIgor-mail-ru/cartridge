local fio = require('fio')
local uuid = require('uuid')
local fiber = require('fiber')
local socket = require('socket')
local utils = require('cartridge.utils')
local etcd_client = require('cartridge.etcd-client')
local t = require('luatest')
local g = t.group()

local etcd = require('cartridge.etcd'):new{}
etcd:discovery()

local helpers = require('test.helper')

g.before_each(function()
    g.datadir = fio.tempdir()
    local password = require('digest').urandom(6):hex()

    fio.mktree(fio.pathjoin(g.datadir, 'etcd'))
    g.etcd = require('luatest.server'):new({
        command = helpers.entrypoint('srv_stateboard'),
        workdir = fio.pathjoin(g.datadir),
        net_box_port = 13301,
        net_box_credentials = {
            user = 'client',
            password = password,
        },
        env = {
            TARANTOOL_PASSWORD = password,
            TARANTOOL_LOCK_DELAY = 40,
            TARANTOOL_CONSOLE_SOCK = fio.pathjoin(g.datadir, 'console.sock'),
            NOTIFY_SOCKET = fio.pathjoin(g.datadir, 'notify.sock'),
            TARANTOOL_PID_FILE = 'etcd.pid',
            TARANTOOL_CUSTOM_PROC_TITLE = 'etcd-proc-title',
        },
    })

    local notify_socket = socket('AF_UNIX', 'SOCK_DGRAM', 0)
    t.assert(notify_socket, 'Can not create socket')
    t.assert(
        notify_socket:bind('unix/', g.etcd.env.NOTIFY_SOCKET),
        notify_socket:error()
    )

    g.etcd:start()

    t.helpers.retrying({}, function()
        t.assert(notify_socket:readable(1), "Socket isn't readable")
        t.assert_str_matches(notify_socket:recv(), 'READY=1')
    end)

    helpers.retrying({}, function()
        g.etcd:connect_net_box()
    end)
end)

g.after_each(function()
    g.etcd:stop()
    fio.rmtree(g.datadir)

    etcd:request('DELETE', '/keys/lock', {})
    etcd:request('DELETE', '/keys/leaders', {})
end)

local function create_client(srv)
    return etcd_client.new({
        uri = 'localhost:' .. srv.net_box_port,
        password = srv.net_box_credentials.password,
        call_timeout = 1,
        lock_delay = g.etcd.env.TARANTOOL_LOCK_DELAY,
        prefix = '/keys'
    })
end

function g.test_locks()
    local c1 = create_client(g.etcd):get_session()
    local c2 = create_client(g.etcd):get_session()
    local kid = uuid.str()

    t.assert_equals(
        c1:acquire_lock({kid, 'localhost:9'}),
        true
    )
    t.assert_equals(
        c1:get_coordinator(),
        {uuid = kid, uri = 'localhost:9'}
    )

    t.assert_equals(
        c2:acquire_lock({uuid.str(), 'localhost:11'}),
        false
    )

    local ok, err = c2:set_leaders({{'A', 'a1'}})
    t.assert_equals(ok, nil)
    t.assert_covers(err, {
        class_name = 'SessionError',
        err = 'You are not holding the lock'
    })

    t.assert_equals(
        c2:get_coordinator(),
        {uuid = kid, uri = 'localhost:9'}
    )

    t.assert(c1:drop(), true)

    local kid = uuid.str()
    helpers.retrying({}, function()
        t.assert_equals({c2:get_coordinator()}, {nil})
    end)

    t.assert_equals(
        c2:acquire_lock({kid, 'localhost:11'}),
        true
    )
    t.assert_equals(
        c2:get_coordinator(),
        {uuid = kid, uri = 'localhost:11'}
    )
end

function g.test_appointments()
    local c = create_client(g.etcd):get_session()
    local kid = uuid.str()
    t.assert_equals(
        c:acquire_lock({kid, 'localhost:9'}),
        true
    )

    t.assert_equals(
        c:set_leaders({{'A', 'a1'}, {'B', 'b1'}}),
        true
    )

    t.assert_equals(
        c:get_leaders(),
        {A = 'a1', B = 'b1'}
    )

    -- local ok, err = c:set_leaders({{'A', 'a2'}, {'A', 'a3'}}) -- TODO Duplicate handle in client
    -- t.assert_equals(ok, nil)
    -- t.assert_covers(err, {
    --     class_name = 'NetboxCallError',
    --     err = "Duplicate key exists in unique index 'ordinal'" ..
    --     " in space 'leader_audit'"
    -- })
end

function g.test_longpolling()
    local c1 = create_client(g.etcd):get_session()
    local kid = uuid.str()
    t.assert_equals(
        c1:acquire_lock({kid, 'localhost:9'}),
        true
    )
    c1:set_leaders({{'A', 'a1'}, {'B', 'b1'}})

    local client = create_client(g.etcd)
    local function async_longpoll()
        local chan = fiber.channel(1)
        fiber.new(function()
            local ret, err = client:longpoll(0.2)
            print(ret)
            chan:put({ret, err})
        end)
        return chan
    end

    t.assert_equals(client:longpoll(0), {A = 'a1', B = 'b1'})

    local chan = async_longpoll()
    c1:set_leaders({{'A', 'a2'}})
    t.assert_equals(chan:get(0.1), {{A = 'a2'}})

    local chan = async_longpoll()
    -- there is no data in channel
    t.assert_equals(chan:get(0.1), nil)

    -- data recieved
    -- t.assert_equals(chan:get(0.2), {{}}) -- TODO
end

function g.test_client_drop_session()
    local client = create_client(g.etcd)
    local session = client:get_session()
    t.assert_equals(session:is_alive(), true)
    t.assert_is(client:get_session(), session)

    local ok = session:acquire_lock({'uuid', 'uri'})
    t.assert_equals(ok, true)
    t.assert_equals(session:is_alive(), true)
    t.assert_equals(session:is_locked(), true)
    t.assert_is(client:get_session(), session)

    client:drop_session()

    local ok, err = session:get_leaders()
    t.assert_equals(ok, nil)
    t.assert_covers(err, {
        class_name = 'SessionError',
        err = 'Session is dropped',
    })

    -- dropping session releases lock and make it dead
    t.assert_equals(session:is_alive(), false)
    t.assert_equals(session:is_locked(), false)

    -- dropping session is idempotent
    client:drop_session()
    t.assert_equals(session:is_alive(), false)
    t.assert_equals(session:is_locked(), false)

    t.assert_is_not(client:get_session(), session)
end

function g.test_client_session()
    -- get_session always returns alive one
    local client = create_client(g.etcd)
    local session = client:get_session()
    t.assert_equals(session:is_alive(), true)
    t.assert_is(client:get_session(), session)

    local ok = session:acquire_lock({'uuid', 'uri'})
    t.assert_equals(ok, true)
    t.assert_equals(session:is_alive(), true)
    t.assert_equals(session:is_locked(), true)
    t.assert_is(client:get_session(), session)

    -- get_session creates new session if old one is dead
    -- g.etcd:stop() -- TODO
    -- t.helpers.retrying({}, function()
    --     t.assert_covers(session.connection, {
    --         state = 'error',
    --         error = 'Peer closed'
    --     })
    -- end)
    client:drop_session()

    local ok, err = session:get_leaders()
    t.assert_equals(ok, nil)
    t.assert_covers(err, {
        class_name = 'SessionError',
        err = 'Session is dropped',
    })
    t.assert_is_not(client:get_session(), session)

    -- session looses lock if connection is interrupded
    t.assert_equals(session:is_alive(), false)
    t.assert_equals(session:is_locked(), false)
end


