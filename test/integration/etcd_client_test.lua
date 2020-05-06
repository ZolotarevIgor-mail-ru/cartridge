local fio = require('fio')
local uuid = require('uuid')
local fiber = require('fiber')
local socket = require('socket')
local utils = require('cartridge.utils')
local etcd_client = require('cartridge.etcd-client')
local t = require('luatest')
local g = t.group()

local etcd = require('moonlibs.etcd'):new{}
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

    etcd:request('DELETE', '/keys/coordinator', {})
    etcd:request('DELETE', '/keys/leaders', {})
end)

local function create_client(srv)
    return etcd_client.new({
        uri = 'localhost:' .. srv.net_box_port,
        password = srv.net_box_credentials.password,
        call_timeout = 1,
        lock_delay = g.etcd.env.TARANTOOL_LOCK_DELAY,
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

    -- local ok, err = c:set_leaders({{'A', 'a2'}, {'A', 'a3'}}) -- TODO Duplicate
    -- t.assert_equals(ok, nil)
    -- t.assert_covers(err, {
    --     class_name = 'NetboxCallError',
    --     err = "Duplicate key exists in unique index 'ordinal'" ..
    --     " in space 'leader_audit'"
    -- })
end
