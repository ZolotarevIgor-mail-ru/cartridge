.. _cartridge-dev:

================================================================================
Tarantool Cartridge developer's guide
================================================================================

For a quick start, skip the details below and jump right away to this detailed
`guide <https://github.com/tarantool/cartridge-cli/blob/master/examples/getting-started-app/README.md>`_
to creating a cluster-aware Tarantool application.

For a deep dive into what you can do with Tarantool Cartridge, go on with this section.

To develop and start an application, in short, you need to go through the
following steps:

#. :ref:`Install <cartridge-install>` Tarantool Cartridge and other
   components of the development environment.
#. Choose a :ref:`template <cartridge-templates>` for the application and
   create a project.
#. Develop the application.
   In case it is a cluster-aware application, implement its logic in
   a custom (user-defined) :ref:`cluster role <cartridge-roles>`
   to initialize the database in a cluster environment.
#. :ref:`Deploy <cartridge-deploy>` the application to target server(s).
   This includes :ref:`configuring <cartridge-config>` and
   :ref:`starting <cartridge-run>` the instance(s).
#. In case it is a cluster-aware application,
   :ref:`deploy the cluster <cartridge-deployment>`.

The following sections provide details for each of these steps.

.. _cartridge-install:

--------------------------------------------------------------------------------
Installing Tarantool Cartridge
--------------------------------------------------------------------------------

#. Install ``catridge-cli``, a command-line tool for developing, deploying, and
   managing Tarantool applications:

   .. code-block:: console

       $ tarantoolctl rocks install cartridge-cli

   The Cartridge framework will come as a dependency when you create your project.

   Everything will be installed to ``.rocks/bin``, so for convenient usage
   add ``.rocks/bin`` to the executable path:

   .. code-block:: console

       $ export PATH=$PWD/.rocks/bin/:$PATH

#. Install ``git``, a version control system.

#. Install ``npm``, a package manager for ``node.js``.

#. Install the ``unzip`` utility.

.. _cartridge-templates:

--------------------------------------------------------------------------------
Application templates
--------------------------------------------------------------------------------

Tarantool Cartridge provides you with two templates that help
instantly set up the application development environment:

* ``plain``, for developing an application that runs on a single or multiple
  independent Tarantool instances (e.g. acting as a proxy to
  third-party databases) -- that's what you could do before,
  :ref:`without Tarantool Cartridge <app_server-creating_app>`,
  but now it's more convenient.
* ``cartridge``, for developing a cluster-aware application -- this is an
  exclusive feature of Tarantool Cartridge.

To create a project based on either template, in any directory say:

.. code-block:: console

    # plain application
    $ plain create --name <app_name> /path/to/

    # - OR -

    # cluster application
    $ cartridge create --name <app_name> /path/to/

This will automatically set up a Git repository in a new ``/path/to/<app_name>/``
directory, tag it with :ref:`version <cartridge-versioning>` ``0.1.0``,
and put the necessary files into it (read about default files for each template
below).

In this Git repository, you can develop the application (by simply editing
the default files provided by the template), plug the necessary
modules, and then easily pack everything to deploy on your server(s).

.. _cartridge-template-plain:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Plain template
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The plain template creates the ``<app_name>/`` directory with the following
contents:

* ``<app_name>-scm-1.rockspec`` file where you can specify the application
  dependencies.
* ``deps.sh`` script that resolves dependencies from the ``.rockspec`` file.
* ``init.lua`` file which is the entry point for your application.
* ``.git`` file necessary for a Git repository.
* ``.gitignore`` file to ignore the unnecessary files.

.. _cartridge-template-cluster:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Cluster template
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

In addition to the files listed in the plain template section, the cluster
template contains the following:

* ``env.lua`` file that sets common rock paths so that the application can be
  started from any directory.
* ``custom-role.lua`` file that is a placeholder for a custom (user-defined)
  :ref:`cluster role <cartridge-roles>`.

The entry point file (``init.lua``) of the cluster template differs from the
plain one. Among other things, it loads the ``cartridge`` module and calls its
initialization function:

.. code-block:: lua

   ...
   local cartridge = require('cartridge')
   ...
   cartridge.cfg({
   -- cartridge options example
     workdir = '/var/lib/tarantool/app',
     advertise_uri = 'localhost:3301',
     cluster_cookie = 'super-cluster-cookie',
     ...
   }, {
   -- box options example
     memtx_memory = 1000000000,
     ... })
    ...

The ``cartridge.cfg()`` call renders the instance operable via the administrative
console but does not call ``box.cfg()`` to configure instances.

.. WARNING::

    Calling the ``box.cfg()`` function is forbidden.

The cluster itself will do it for you when it is time to:

* bootstrap the current instance once you:

  * run ``cartridge.bootstrap()`` via the administrative console, or
  * click **Create** in the web interface;

* join the instance to an existing cluster once you:

  * run ``cartridge.join_server({uri = 'other_instance_uri'})`` via the console, or
  * click **Join** (an existing replica set) or **Create** (a new replica set)
    in the web interface.

Notice that you can specify a cookie for the cluster (``cluster_cookie`` parameter)
if you need to run several clusters in the same network. The cookie can be any
string value.

Before developing a cluster-aware application, familiarize yourself with
the notion of :ref:`cluster roles <cartridge-roles>`
and make sure to define a custom role to initialize the database for the cluster
application.

.. _cartridge-roles:

--------------------------------------------------------------------------------
Cluster roles
--------------------------------------------------------------------------------

A Tarantool Cartridge cluster segregates instance functionality in a role-based
way. **Cluster roles** are Lua modules that implement some instance-specific
functions and/or logic.

Since all instances running cluster applications use the same source code and
are aware of all the defined roles (and plugged modules), multiple different
roles can be dynamically enabled and disabled on any number of instances
without restarts even during cluster operation.

.. _cartridge-built-in-roles:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Built-in roles
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The ``cartridge`` module comes with two *built-in* roles that implement
automatic sharding:

* ``vshard-router`` that handles the ``vshard``'s *compute-intensive* workload:
  routes requests to storage nodes.
* ``vshard-storage`` that handles the ``vshard``'s *transaction-intensive*
  workload: stores and manages a subset of a dataset.

  .. NOTE::

     For more information on sharding, see the
     :ref:`vshard module documentation <vshard>`.

With the built-in and custom roles, Tarantool Cartridge allows you to develop
applications with separated compute and transaction handling. Later, the
relevant workload-specific roles can be enabled on different instances running
on physical servers with workload-dedicated hardware.

Neither ``vshard-router`` nor ``vshard-storage`` manage spaces, indexes, or
formats. To start developing an application, edit the ``custom-role.lua``
placeholder file: add a ``box.schema.space.create()`` call to your first
cluster role.

Additionally, you can implement several such roles to:

* define stored procedures;
* implement functionality on top of ``vshard``;
* go without ``vshard`` at all;
* implement one or multiple supplementary services such as
  e-mail notifier, replicator, etc.

.. _cartridge-custom-roles:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Custom roles
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

To implement a *custom* cluster role, do the following:

#. Register the new role in the cluster by modifying the ``cartridge.cfg()``
   call in the ``init.lua`` entry point file:

   .. code-block:: lua
      :emphasize-lines: 7

      ...
      local cartridge = require('cartridge')
      ...
      cartridge.cfg({
        workdir = ...,
        advertise_uri = ...,
        roles = {'custom-role'},
      })
      ...

   where ``custom-role`` is the name of the Lua module to be loaded.

#. Implement the role in a file with the appropriate name (``custom-role.lua``).
   For example:

   .. code-block:: lua

      #!/usr/bin/env tarantool
      -- Custom role implementation
      local role_name = 'custom-role'

      local function init()
      ...
      end

      local function stop()
      ...
      end

      return {
          role_name = role_name,
          init = init,
          stop = stop,
      }

   Where the ``role_name`` may differ from the module name passed to the
   ``cartridge.cfg()`` function. If the ``role_name`` variable is not specified,
   the module name is the default value.

   .. NOTE::

      Role names must be unique as it is impossible to register multiple
      roles with the same name.

The role module does not have required functions but the cluster may execute the
following ones during the role's life cycle:

* ``init()`` is the role's *initialization* function.

  Inside the function's body you can call any ``box`` functions:
  create spaces, indexes, grant permissions, etc. Here is what the
  initialization function may look like:

  .. code-block:: lua
     :emphasize-lines: 3

     local function init(opts)
         -- The cluster passes an 'opts' Lua table containing an 'is_master' flag.
         if opts.is_master then
             local customer = box.schema.space.create('customer',
                 { if_not_exists = true }
             )
             customer:format({
                 {'customer_id', 'unsigned'},
                 {'bucket_id', 'unsigned'},
                 {'name', 'string'},
             })
             customer:create_index('customer_id', {
                 parts = {'customer_id'},
                 if_not_exists = true,
             })
         end
     end

  .. NOTE::

     The function's body is wrapped in a conditional statement that
     lets you call ``box`` functions on masters only. This protects
     against replication collisions as data propagates to replicas
     automatically.

* ``stop()`` is the role's *termination* function. Implement it if
  initialization starts a fiber that has to be stopped or does any job that
  has to be undone on termination.

* ``validate_config()`` and ``apply_config()`` are *validation* and
  *application* functions that make custom roles configurable. Implement
  them if some configuration data has to be stored cluster-wide.

Next, get a grip on the :ref:`role's life cycle <cartridge-role-lifecycle>` to
implement the necessary functions.

.. _cartridge-role-dependencies:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Defining role dependencies
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

You can instruct the cluster to apply some other roles if your custom role
is enabled.

For example:

   .. code-block:: lua

      -- Role dependencies defined in custom-role.lua
      local role_name = 'custom-role'
      ...
      return {
          role_name = role_name,
          dependencies = {'cartridge.roles.vshard-router'},
          ...
      }

Here ``vshard-router`` role will be initialized automatically for every
instance with ``custom-role`` enabled.

.. _cartridge-vshard-groups:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Using multiple vshard storage groups
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Replica sets with ``vshard-storage`` roles can belong to different *groups*.
For example, ``hot`` or ``cold`` groups meant to independently process hot and
cold data.

Groups are specified in the cluster's configuration:

.. code-block:: lua

    cartridge.cfg({
        vshard_groups = {'hot', 'cold'},
        ...
    })

If no groups are specified, the cluster assumes that all replica sets belong
to the ``default`` group.

With multiple groups enabled, every replica set with a ``vshard-storage`` role
enabled must be assigned to a particular group.
The assignment can never be changed.

Another limitation is that you cannot add groups dynamically
(this will become available in future).

Finally, mind the new syntax for router access.
Every instance with a ``vshard-router`` role enabled initializes multiple
routers. All of them are accessible through the role:

.. code-block:: lua

    local router_role = cartridge.service_get('vshard-router')
    router_role.get('hot'):call(...)

If you have no roles specified, you can access a static router as before:

.. code-block:: lua

    local vhsard = require('vshard')
    vshard.router.call(...)

However, when using the new API, you must call a static router with a colon:

.. code-block:: lua

    local router_role = cartridge.service_get('vshard-router')
    local default_router = router_role.get() -- or router_role.get('default')
    default_router:call(...)

.. _cartridge-role-lifecycle:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Role's life cycle and the order of function execution
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The cluster displays all custom role names along with the built-in ``vshard``
ones in the web interface. Cluster administrators can enable and disable
them for particular instances either via the web interface or cluster public
API. For example:

.. code-block:: kconfig

    cartridge.admin.edit_replicaset('replicaset-uuid', {roles = {'vshard-router', 'custom-role'}})

If multiple roles are enabled on an instance at the same time, the cluster first
initializes the built-in roles (if any) and then the custom ones (if any) in the
order the latter were listed in ``cartridge.cfg()``.

If a custom role has dependent roles, the dependencies are registered and
validated first, prior to the role itself.

The cluster calls the role's functions in the following circumstances:

* The ``init()`` function, typically, once: either when the role is enabled by
  the administrator or at the instance restart. Enabling a role once is normally
  enough.

* The ``stop()`` function -- only when the administrator disables the
  role, not on instance termination.

* The ``validate_config()`` function, first, before the automatic ``box.cfg()``
  call (database initialization), then -- upon every configuration update.

* The ``apply_config()`` function upon every configuration update.

Hence, if the cluster is tasked with performing the following actions, it
will execute the functions listed in the following order:

* Join an instance or create a replica set, both with an enabled role:

  #. ``validate_config()``
  #. ``init()``
  #. ``apply_config()``

* Restart an instance with an enabled role:

  #. ``validate_config()``
  #. ``init()``
  #. ``apply_config()``

* Disable role: ``stop()``.

* Upon the ``cartridge.confapplier.patch_clusterwide()`` call:

  #. ``validate_config()``
  #. ``apply_config()``

* Upon a triggered failover:

  #. ``validate_config()``
  #. ``apply_config()``

Considering the described behavior:

* The ``init()`` function may:

  * Call ``box`` functions.
  * Start a fiber and, in this case, the ``stop()`` function should
    take care of the fiber's termination.
  * Configure the built-in :ref:`HTTP server <cartridge-httpd-instance>`.
  * Execute any code related to the role's initialization.

* The ``stop()`` functions must undo any job that has to be undone on role's
  termination.

* The ``validate_config()`` function must validate any configuration change.

* The ``apply_config()`` function may execute any code related to a configuration
  change, e.g., take care of an ``expirationd`` fiber.

The validation and application functions together allow you to customize the
cluster-wide configuration as described in the
:ref:`next section <cartridge-role-config>`.

.. _cartridge-role-config:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Configuring custom roles
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

You can:

* Store configurations for your custom roles as sections in cluster-wide
  configuration, for example:

  .. code-block:: yaml

      # YAML configuration file
      my_role:
        notify_url: "https://localhost:8080"

  .. code-block:: lua

      -- init.lua file
      local notify_url = 'http://localhost'
      function my_role.apply_config(conf, opts)
        local conf = conf['my_role'] or {}
        notify_url = conf.notify_url or 'default'
      end

* Download and upload cluster-wide configuration using
  :ref:`cluster UI <cartridge-ui-configuration>` or
  API (via GET/PUT queries to ``admin/config`` endpoint like
  ``curl localhost:8081/admin/config`` and
  ``curl -X PUT -d "{'my_parameter': 'value'}" localhost:8081/admin/config``).

* Utilize it in your role ``apply_config()`` function.

Every instance in the cluster stores a copy of the configuration file in its
working directory (configured by ``cartridge.cfg({workdir = ...})``):

* ``/var/lib/tarantool/<instance_name>/config.yml`` for instances deployed from
  RPM packages and managed by ``systemd``.
* ``/home/<username>/tarantool_state/var/lib/tarantool/config.yml`` for
  instances deployed from archives.

The cluster's configuration is a Lua table, downloaded and uploaded as YAML.
If some application-specific configuration data, e.g., a database schema as
defined by DDL (data definition language), has to be stored on every instance
in the cluster, you can implement your own API by adding a custom section to
the table. The cluster will help you spread it safely across all instances.

Such section goes in parallel (in the same file) with the topology-specific
and ``vshard``-specific ones the cluster automatically generates.
Unlike the generated, the custom section's modification, validation, and
application logic has to be defined.

The common way is to define two functions:

* ``validate_config(conf_new, conf_old)`` to validate changes made in the
  new configuration (``conf_new``) versus the old configuration (``conf_old``).
* ``apply_config(conf, opts)`` to execute any code related to a configuration
  change. As input, this function takes the configuration to apply (``conf``,
  which is actually the new configuration that you validated earlier with
  ``validate_config()``) and options (the ``opts`` argument that includes
  ``is_master``, a Boolean flag described later).

.. IMPORTANT::

    The ``validate_config()`` function must detect all configuration
    problems that may lead to ``apply_config()`` errors. For more information,
    see the :ref:`next section <cartridge-role-config-apply>`.

When implementing validation and application functions that call ``box``
ones for some reason, the following precautions apply:

* Due to the :ref:`role's life cycle <cartridge-role-lifecycle>`, the cluster
  does not guarantee an automatic ``box.cfg()`` call prior to calling
  ``validate_config()``.

  If the validation function is to call any ``box`` functions (e.g., to check
  a format), make sure the calls are wrapped in a protective conditional
  statement that checks if ``box.cfg()`` has already happened:

  .. code-block:: Lua
     :emphasize-lines: 3

     -- Inside the validation function:

     if type(box.cfg) == 'table' then

         -- Here you can call box functions

     end

* Unlike the validation and similar to initialization function,
  ``apply_config()`` can call ``box`` functions freely as the cluster applies
  custom configuration after the automatic ``box.cfg()`` call.

  However, creating spaces, users, etc., can cause replication collisions when
  performed on both master and replica instances simultaneously. The appropriate
  way is to call such ``box`` functions on masters only and let the changes
  propagate to replicas automatically.

  Upon the ``apply_config(conf, opts)`` execution, the cluster passes an
  ``is_master`` flag in the ``opts`` table which you can use to wrap
  collision-inducing ``box`` functions in a protective conditional statement:

  .. code-block:: Lua
     :emphasize-lines: 3

     -- Inside the configuration application function:

     if opts.is_master then

         -- Here you can call box functions

     end

.. _cartridge-role-config-example:

****************************
Custom configuration example
****************************

Consider the following code as part of the role's module (``custom-role.lua``)
implementation:

.. code-block:: lua

   #!/usr/bin/env tarantool
   -- Custom role implementation

   local cartridge = require('cartridge')

   local role_name = 'custom-role'

   -- Modify the config by implementing some setter (an alternative to HTTP PUT)
   local function set_secret(secret)
       local custom_role_cfg = cartridge.confapplier.get_deepcopy(role_name) or {}
       custom_role_cfg.secret = secret
       cartridge.confapplier.patch_clusterwide({
           [role_name] = custom_role_cfg,
       })
   end
   -- Validate
   local function validate_config(cfg)
       local custom_role_cfg = cfg[role_name] or {}
       if custom_role_cfg.secret ~= nil then
           assert(type(custom_role_cfg.secret) == 'string', 'custom-role.secret must be a string')
       end
       return true
   end
   -- Apply
   local function apply_config(cfg)
       local custom_role_cfg = cfg[role_name] or {}
       local secret = custom_role_cfg.secret or 'default-secret'
       -- Make use of it
   end

   return {
       role_name = role_name,
       set_secret = set_secret,
       validate_config = validate_config,
       apply_config = apply_config,
   }

Once the configuration is customized, do one of the following:

* continue developing your application and pay attention to its
  :ref:`versioning <cartridge-versioning>`;
* (optional) :ref:`enable authorization <cartridge-auth-enable>` in the web interface.
* in case the cluster is already deployed,
  :ref:`apply the configuration <cartridge-role-config-apply>` cluster-wide.

.. _cartridge-role-config-apply:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Applying custom role's configuration
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

With the implementation showed by the :ref:`example <cartridge-role-config-example>`,
you can call the ``set_secret()`` function to apply the new configuration via
the administrative console or an HTTP endpoint if the role exports one.

The ``set_secret()`` function calls ``cartridge.confapplier.patch_clusterwide()``
which performs a two-phase commit:

#. It patches the active configuration in memory: copies the table and replaces
   the ``"custom-role"`` section in the copy with the one given by the
   ``set_secret()`` function.

#. The cluster checks if the new configuration can be applied on all instances
   except disabled and expelled. All instances subject to update must be healthy
   and ``alive`` according to the
   `membership module <https://www.tarantool.io/en/doc/1.10/reference/reference_rock/membership/>`_.

#. (**Preparation phase**) The cluster propagates the patched configuration.
   Every instance validates it with the ``validate_config()`` function of
   every registered role. Depending on the validation's result:

   * If successful (i.e., returns ``true``), the instance saves the new
     configuration to a temporary file named ``config.prepare.yml`` within the
     working directory.
   * (**Abort phase**) Otherwise, the instance reports an error and all other
     instances roll back the update: remove the file they may have already
     prepared.

#. (**Commit phase**) Upon successful preparation of all instances, the cluster
   commits the changes. Every instance:

   #. Creates the active configuration's hard-link.
   #. Atomically replaces the active one with the prepared. The atomic
      replacement is indivisible -- it can either succeed or fail entirely,
      never partially.
   #. Calls the ``apply_config()`` function of every registered role.

If any of these steps fail, an error pops up in the web interface next to the
corresponding instance. The cluster does not handle such errors automatically,
they require manual repair.

You will avoid the repair if the ``validate_config()`` function can detect all
configuration problems that may lead to ``apply_config()`` errors.

.. _cartridge-httpd-instance:

-------------------------------------------------------------------------------
Using the built-in HTTP server
-------------------------------------------------------------------------------

The cluster launches an ``httpd`` server instance during initialization
(``cartridge.cfg()``). You can bind a port to the instance via an environmental
variable:

.. code-block:: Lua

   -- Get the port from an environmental variable or the default one:
   local http_port = os.getenv('HTTP_PORT') or '8080'

   local ok, err = cartridge.cfg({
      ...
      -- Pass the port to the cluster:
      http_port = http_port,
      ...
   })

To make use of the ``httpd`` instance, access it and configure routes inside
the ``init()`` function of some role, e.g. a role that exposes API over HTTP:

.. code-block:: Lua

   local function init(opts)

   ...

      -- Get the httpd instance:
      local httpd = cartridge.service_get('httpd')
      if httpd ~= nil then
          -- Configure a route to, for example, metrics:
          httpd:route({
                  method = 'GET',
                  path = '/metrics',
                  public = true,
              },
              function(req)
                  return req:render({json = stat.stat()})
              end
          )
      end
   end

For more information on the usage of Tarantool's HTTP server, see
`its documentation <https://github.com/tarantool/http>`_.

.. _cartridge-auth-enable:

-------------------------------------------------------------------------------
Implementing authorization in the web interface
-------------------------------------------------------------------------------

To implement authorization in the web interface of every instance in Tarantool
cluster:

#. Implement a new, say, ``auth`` module with a ``check_password`` function. It
   should check the credentials of any user trying to log in to the web interface.

   The ``check_password`` function accepts a username and password and returns
   an authentication success or failure.

   .. code-block:: Lua

      -- auth.lua

      -- Add a function to check the credentials
      local function check_password(username, password)

          -- Check the credentials any way you like

          -- Return an authentication success or failure
          if not ok then
              return false
          end
          return true
      end
      ...

#. Pass the implemented ``auth`` module name as a parameter to ``cartridge.cfg()``,
   so the cluster can use it:

   .. code-block:: Lua

      -- init.lua

      local ok, err = cartridge.cfg({
          auth_backend_name = 'auth',
          -- The cluster will automatically call 'require()' on the 'auth' module.
          ...
      })

   This adds a **Log in** button to the upper right corner of the
   web interface but still lets the unsigned users interact with the interface.
   This is convenient for testing.

   .. NOTE::

      Also, to authorize requests to cluster API, you can use the HTTP basic
      authorization header.

#. To require the authorization of every user in the web interface even before
   the cluster bootstrap, add the following line:

   .. code-block:: Lua
      :emphasize-lines: 5

      -- init.lua

      local ok, err = cartridge.cfg({
          auth_backend_name = 'auth',
          auth_enabled = true,
          ...
      })

   With the authentication enabled and the ``auth`` module implemented, the user
   will not be able to even bootstrap the cluster without logging in.
   After the successful login and bootstrap, the authentication can be enabled
   and disabled cluster-wide in the web interface and the ``auth_enabled`` parameter
   is ignored.

.. _cartridge-versioning:

-------------------------------------------------------------------------------
Application versioning
-------------------------------------------------------------------------------

Tarantool Cartridge understands semantic versioning as described at
`semver.org <https://semver.org>`_.
When developing an application, create new Git branches and tag them appropriately.
These tags are used to calculate version increments for subsequent packaging.

For example, if your application has version 1.2.1, tag your current branch with
``1.2.1`` (annotated or not).

To retrieve the current version from Git, say:

.. code-block:: console

    $ git describe --long --tags
    1.2.1-12-g74864f2

This output shows that we are 12 commits after the version 1.2.1. If we are
to package the application at this point, it will have a full version of
``1.2.1-12`` and its package will be named ``<app_name>-1.2.1-12.rpm``.

Non-semantic tags are prohibited. You will not be able to create a package from
a branch with the latest tag being non-semantic.

Once you :ref:`package <cartridge-deploy>` your application, the version
is saved in a ``VERSION`` file in the package root.

.. _cartridge-app-ignore:

-------------------------------------------------------------------------------
Using .cartridge.ignore files
-------------------------------------------------------------------------------

You can add a ``.cartridge.ignore`` file to your application repository to
exclude particular files and/or directories from package builds.

For the most part, the logic is similar to that of ``.gitignore`` files.
The major difference is that in ``.cartridge.ignore`` files the order of
exceptions relative to the rest of the templates does not matter, while in
``.gitignore`` files the order does matter.

.. container:: table

    .. rst-class:: left-align-column-1
    .. rst-class:: left-align-column-2

    +---------------------------------+-------------------------------------------------+
    | **.cartridge.ignore** entry     | ignores every...                                |
    +=================================+=================================================+
    | ``target/``                     | **folder** (due to the trailing ``/``)          |
    |                                 | named ``target``, recursively                   |
    +---------------------------------+-------------------------------------------------+
    | ``target``                      | **file or folder** named ``target``,            |
    |                                 | recursively                                     |
    +---------------------------------+-------------------------------------------------+
    | ``/target``                     | **file or folder** named ``target`` in the      |
    |                                 | top-most directory (due to the leading ``/``)   |
    +---------------------------------+-------------------------------------------------+
    | ``/target/``                    | **folder** named ``target`` in the top-most     |
    |                                 | directory (leading and trailing ``/``)          |
    +---------------------------------+-------------------------------------------------+
    | ``*.class``                     | every **file or folder** ending with            |
    |                                 | ``.class``, recursively                         |
    +---------------------------------+-------------------------------------------------+
    | ``#comment``                    | nothing, this is a comment (the first           |
    |                                 | character is a ``#``)                           |
    +---------------------------------+-------------------------------------------------+
    | ``\#comment``                   | every **file or folder** with name              |
    |                                 | ``#comment`` (``\`` for escaping)               |
    +---------------------------------+-------------------------------------------------+
    | ``target/logs/``                | every **folder** named ``logs`` which is        |
    |                                 | a subdirectory of a folder named ``target``     |
    +---------------------------------+-------------------------------------------------+
    | ``target/*/logs/``              | every **folder** named ``logs`` two levels      |
    |                                 | under a folder named ``target`` (``*`` doesn’t  |
    |                                 | include ``/``)                                  |
    +---------------------------------+-------------------------------------------------+
    | ``target/**/logs/``             | every **folder** named ``logs`` somewhere       |
    |                                 | under a folder named ``target`` (``**``         |
    |                                 | includes ``/``)                                 |
    +---------------------------------+-------------------------------------------------+
    | ``*.py[co]``                    | every **file or folder** ending in ``.pyc`` or  |
    |                                 | ``.pyo``; however, it doesn’t match ``.py!``    |
    +---------------------------------+-------------------------------------------------+
    | ``*.py[!co]``                   | every **file or folder** ending in anything     |
    |                                 | other than ``c`` or ``o``                       |
    +---------------------------------+-------------------------------------------------+
    | ``*.file[0-9]``                 | every **file or folder** ending in digit        |
    +---------------------------------+-------------------------------------------------+
    | ``*.file[!0-9]``                | every **file or folder** ending in anything     |
    |                                 | other than digit                                |
    +---------------------------------+-------------------------------------------------+
    | ``*``                           | **every**                                       |
    +---------------------------------+-------------------------------------------------+
    | ``/*``                          | **everything** in the top-most directory (due   |
    |                                 | to the leading ``/``)                           |
    +---------------------------------+-------------------------------------------------+
    | ``**/*.tar.gz``                 | every ``*.tar.gz`` file or folder which is      |
    |                                 | **one or more** levels under the starting       |
    |                                 | folder                                          |
    +---------------------------------+-------------------------------------------------+
    | ``!file``                       | every **file or folder** will be ignored even   |
    |                                 | if it matches other patterns                    |
    +---------------------------------+-------------------------------------------------+

.. _cartridge-deploy:

--------------------------------------------------------------------------------
Deploying an application
--------------------------------------------------------------------------------

You have four options to deploy a Tarantool Cartridge application:

* as an :ref:`rpm <cartridge-deploy-rpm>` package (for production);
* as a :ref:`deb <cartridge-deploy-deb>` package (for production);
* as a :ref:`tar+gz <cartridge-deploy-tgz>` archive (for testing,
  or as a workaround for production if root access is unavailable).
* :ref:`from sources <cartridge-deploy-rock>` (for local testing only).

.. _cartridge-deploy-rpm:
.. _cartridge-deploy-deb:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Deploying as an rpm or deb package
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

#. Pack the application into a distributable:

   .. code-block:: console

       $ cartridge pack rpm APP_NAME
       # -- OR --
       $ cartridge pack deb APP_NAME

   This will create an RPM package (e.g. ``./my_app-0.1.0-1.rpm``) or
   a DEB package (e.g. ``./my_app-0.1.0-1.deb``).

#. Upload the package to target servers, with ``systemctl`` supported.

#. Install:

   .. code-block:: console

       $ yum install APP_NAME-VERSION.rpm
       # -- OR --
       $ dpkg -i APP_NAME-VERSION.deb

#. :ref:`Configure the instance(s) <cartridge-config>`.

#. Start Tarantool instances with the corresponding services.
   You can do it using :ref:`systemctl <cartridge-run-systemctl>`, for example:

   .. code-block:: console

       # starts a single instance
       $ systemctl start my_app

       # starts multiple instances
       $ systemctl start my_app@router
       $ systemctl start my_app@storage_A
       $ systemctl start my_app@storage_B

#. In case it is a cluster-aware application, proceed to
   :ref:`deploying the cluster <cartridge-deployment>`.

.. _cartridge-deploy-tgz:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Deploying as a tar+gz archive
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

#. Pack the application into a distributable:

   .. code-block:: console

       $ cartridge pack tgz APP_NAME

   This will create a tar+gz archive (e.g. ``./my_app-0.1.0-1.tgz``).

#. Upload the archive to target servers, with ``tarantool`` and (optionally)
   :ref:`cartridge-cli <cartridge-install>` installed.

#. Extract the archive:

   .. code-block:: console

       $ tar -xzvf APP_NAME-VERSION.tgz

#. :ref:`Configure the instance(s) <cartridge-config>`.

#. Start Tarantool instance(s). You can do it using:

   * :ref:`tarantool <cartridge-run-tarantool>`, for example:

     .. code-block:: console

         $ tarantool init.lua # starts a single instance

   * or :ref:`cartridge <cartridge-run-cartridge>`, for example:

     .. code-block:: console

         # in application directory
         $ cartridge start # starts all instances
         $ cartridge start .router_1 # starts a single instance

         # in multi-application environment
         $ cartridge start my_app # starts all instances of my_app
         $ cartridge start my_app.router # starts a single instance

#. In case it is a cluster-aware application, proceed to
   :ref:`deploying the cluster <cartridge-deployment>`.

.. _cartridge-deploy-rock:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Deploying from sources
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

This deployment method is intended for local testing only.

#. Pull all dependencies to the ``.rocks`` directory:

   $ tarantoolctl rocks make

#. :ref:`Configure the instance(s) <cartridge-config>`.

#. Start Tarantool instance(s). You can do it using:

   * :ref:`tarantool <cartridge-run-tarantool>`, for example:

     .. code-block:: console

         $ tarantool init.lua # starts a single instance

   * or :ref:`cartridge <cartridge-run-cartridge>`, for example:

     .. code-block:: console

         # in application directory
         cartridge start # starts all instances
         cartridge start .router_1 # starts a single instance

         # in multi-application environment
         cartridge start my_app # starts all instances of my_app
         cartridge start my_app.router # starts a single instance

#. In case it is a cluster-aware application, proceed to
   :ref:`deploying the cluster <cartridge-deployment>`.

.. _cartridge-config:

--------------------------------------------------------------------------------
Configuring instances
--------------------------------------------------------------------------------

Instance configuration includes two sets of parameters:

* `cartridge.cfg() parameters <https://www.tarantool.io/en/rocks/cartridge/1.0/modules/cartridge.argparse/#cluster-opts>`_;
* `box.cfg() parameters <https://www.tarantool.io/en/rocks/cartridge/1.0/modules/cartridge.argparse/#box-opts>`_.

You can set any of these parameters in:

#. Command line arguments.
#. Environment variables.
#. YAML configuration file.
#. ``init.lua`` file.

The order here indicates the priority: command-line arguments override
environment variables, and so forth.

No matter how you :ref:`start the instances <cartridge-run>`, you need to set
the following ``cartridge.cfg()`` parameters for each instance:

* ``advertise_uri`` -- either ``<HOST>:<PORT>``, or ``<HOST>:``, or ``<PORT>``.
  Used by other instances to connect to the current one.
  **DO NOT** specify ``0.0.0.0`` -- this must be
  an external IP address, not a socket bind.
* ``http_port`` -- port to open administrative web interface and API on.
  Defaults to ``8081``.
  To disable it, specify ``"http_enabled": False``.
* ``workdir`` -- a directory where all data will be stored:
  snapshots, wal logs, and ``cartridge`` configuration file.
  Defaults to ``.``.

.. _cartridge-config-cartridge-cli:
.. _cartridge-config-systemctl:

If you start instances using ``cartridge`` CLI or ``systemctl``,
save the configuration as a YAML file, for example:

.. code-block:: kconfig

    my_app.router: {"advertise_uri": "localhost:3301", "http_port": 8080}
    my_app.storage_A: {"advertise_uri": "localhost:3302", "http_enabled": False}
    my_app.storage_B: {"advertise_uri": "localhost:3303", "http_enabled": False}

With ``cartridge`` CLI, you can pass the path to this file as the ``--cfg``
command-line argument to the ``cartridge start`` command -- or specify the path
in ``cartridge`` CLI configuration (in ``./.cartridge.yml`` or ``~/.cartridge.yml``):

.. code-block:: kconfig

    cfg: cartridge.yml
    run_dir: tmp/run
    apps_path: /usr/local/share/tarantool

With ``systemctl``, save the YAML file to ``/etc/tarantool/conf.d/``
(the default ``systemd`` path) or to a location set in the ``TARANTOOL_CFG``
environment variable.

.. _cartridge-config-tarantool:

If you start instances with ``tarantool init.lua``,
you need to pass other configuration options as command-line parameters and
environment variables, for example:

.. code-block:: console

    $ tarantool init.lua --alias router --memtx-memory 100 --workdir "~/db/3301" --advertise_uri "localhost:3301" --http_port "8080"

.. _cartridge-run:

--------------------------------------------------------------------------------
Starting/stopping instances
--------------------------------------------------------------------------------

Depending on your :ref:`deployment method <cartridge-deploy>`, you can start/stop
the instances using :ref:`tarantool <cartridge-run-tarantool>`,
:ref:`cartridge CLI <cartridge-run-cartridge>`, or
:ref:`systemctl <cartridge-run-systemctl>`.

.. _cartridge-run-tarantool:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Start/stop using ``tarantool``
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

With ``tarantool``, you can start only a single instance:

.. code-block:: console

    $ tarantool init.lua # the simplest command

You can also :ref:`specify more options <cartridge-config-tarantool>`
on the command line or in environment variables.

To stop the instance, use Ctrl+C.

.. _cartridge-run-cartridge:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Start/stop using ``cartridge`` CLI
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

With ``cartridge`` CLI, you can start one or multiple instances:

.. code-block:: console

    $ cartridge start [APP_NAME[.INSTANCE_NAME]] [options]

The options are:

``--script FILE``
        Application's entry point.
        Defaults to:

        *  ``TARANTOOL_SCRIPT``, or
        * ``./init.lua`` when running from the app's directory, or
        * ``:apps_path/:app_name/init.lua`` in a multi-app environment.

``--apps_path PATH``
        Path to apps directory when running in a multi-app environment.
        Defaults to ``/usr/share/tarantool``.

``--run_dir DIR``
        Directory with pid and sock files.
        Defaults to ``TARANTOOL_RUN_DIR`` or ``/var/run/tarantool``.

``--cfg FILE``
        Cartridge instances YAML configuration file.
        Defaults to ``TARANTOOL_CFG`` or ``./instances.yml``.

``--foreground``
        Do not daemonize.

For example:

.. code-block:: console

    cartridge start my_app --cfg demo.yml --run_dir ./tmp/run --foreground

It starts all ``tarantool`` instances specified in ``cfg`` file, in foreground,
with enforced :ref:`environment variables <cartridge-config>`.

When ``APP_NAME`` is not provided, ``cartridge`` parses it from ``./*.rockspec``
filename.

When ``INSTANCE_NAME`` is not provided, ``cartridge`` reads ``cfg`` file and
starts all defined instances:

.. code-block:: console

    # in application directory
    cartridge start # starts all instances
    cartridge start .router_1 # start single instance

    # in multi-application environment
    cartridge start my_app # starts all instances of my_app
    cartridge start my_app.router # start a single instance

To stop the instances, say:

.. code-block:: console

    $ cartridge stop [APP_NAME[.INSTANCE_NAME]] [options]

These options from the ``cartridge start`` command are supported:

* ``--run_dir DIR``
* ``--cfg FILE``

.. _cartridge-run-systemctl:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Start/stop using ``systemctl``
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

* To run a single instance:

  .. code-block:: console

      $ systemctl start APP_NAME

  This will start a  ``systemd`` service that will listen to the
  port specified in :ref:`instance configuration <cartridge-config>`
  (``http_port`` parameter).

* To run multiple instances on one or multiple servers:

  .. code-block:: console

      $ systemctl start APP_NAME@INSTANCE_1
      $ systemctl start APP_NAME@INSTANCE_2
      ...
      $ systemctl start APP_NAME@INSTANCE_N

  where ``APP_NAME@INSTANCE_N`` is the instantiated service name
  for ``systemd`` with an incremental ``N`` -- a number, unique for every
  instance, added to the port the instance will listen to
  (e.g., ``3301``, ``3302``, etc.)

* To stop all services on a server, use the ``systemctl stop`` command
  and specify instance names one by one. For example:

  .. code-block:: console

      $ systemctl stop APP_NAME@INSTANCE_1 APP_NAME@INSTANCE_2 ... APP_NAME@INSTANCE_<N>
