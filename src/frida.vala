namespace Frida {
	public class DeviceManager : Object {
		public signal void changed ();

		public MainContext main_context {
			get;
			private set;
		}

		private bool is_closed = false;

		private HostSessionService service = null;
		private Gee.ArrayList<Device> devices = new Gee.ArrayList<Device> ();
		private uint last_device_id = 1;

		public DeviceManager (MainContext main_context) {
			this.main_context = main_context;
		}

		public override void dispose () {
			close_sync ();
			base.dispose ();
		}

		public async void close () {
			if (is_closed)
				return;
			is_closed = true;

			yield _do_close ();
		}

		public void close_sync () {
			try {
				(create<CloseTask> () as CloseTask).start_and_wait_for_completion ();
			} catch (Error e) {
				assert_not_reached ();
			}
		}

		private class CloseTask : ManagerTask<void> {
			protected override void validate_operation () throws Error {
			}

			protected override async void perform_operation () throws Error {
				yield parent.close ();
			}
		}

		public async Gee.List<Device> enumerate_devices () throws Error {
			yield ensure_service ();
			return devices.slice (0, devices.size);
		}

		public Gee.List<Device> enumerate_devices_sync () throws Error {
			return (create<EnumerateTask> () as EnumerateTask).start_and_wait_for_completion ();
		}

		private class EnumerateTask : ManagerTask<Gee.List<Device>> {
			protected override async Gee.List<Device> perform_operation () throws Error {
				return yield parent.enumerate_devices ();
			}
		}

		public void _release_device (Device device) {
			var device_did_exist = devices.remove (device);
			assert (device_did_exist);
		}

		private async void ensure_service () throws IOError {
			if (service != null)
				return;

			service = new HostSessionService.with_default_backends ();
			service.provider_available.connect ((provider) => {
				var device = new Device (this, last_device_id++, provider.name, provider.kind, provider);
				devices.add (device);
				changed ();
			});
			service.provider_unavailable.connect ((provider) => {
				foreach (var device in devices) {
					if (device.provider == provider) {
						device._do_close (false);
						break;
					}
				}
				changed ();
			});
			yield service.start ();
		}

		private async void _do_close () {
			if (service == null)
				return;

			foreach (var device in devices.to_array ())
				yield device._do_close (true);
			devices.clear ();

			yield service.stop ();
			service = null;
		}

		private Object create<T> () {
			return Object.new (typeof (T), main_context: main_context, parent: this);
		}

		private abstract class ManagerTask<T> : AsyncTask<T> {
			public weak DeviceManager parent {
				get;
				construct;
			}

			protected override void validate_operation () throws Error {
				if (parent.is_closed)
					throw new IOError.FAILED ("invalid operation (manager is closed)");
			}
		}
	}

	public class Device : Object {
		public signal void closed ();

		public uint id {
			get;
			private set;
		}

		public string name {
			get;
			private set;
		}

		public string kind {
			get;
			private set;
		}

		public Frida.HostSessionProvider provider {
			get;
			private set;
		}

		public MainContext main_context {
			get;
			private set;
		}

		private weak DeviceManager manager;
		private bool is_closed = false;

		protected Frida.HostSession host_session;
		private Gee.HashMap<uint, Session> session_by_pid = new Gee.HashMap<uint, Session> ();
		private Gee.HashMap<uint, Session> session_by_handle = new Gee.HashMap<uint, Session> ();

		public Device (DeviceManager manager, uint id, string name, Frida.HostSessionProviderKind kind, Frida.HostSessionProvider provider) {
			this.manager = manager;
			this.id = id;
			this.name = name;
			switch (kind) {
				case Frida.HostSessionProviderKind.LOCAL_SYSTEM:
					this.kind = "local";
					break;
				case Frida.HostSessionProviderKind.LOCAL_TETHER:
					this.kind = "tether";
					break;
				case Frida.HostSessionProviderKind.REMOTE_SYSTEM:
					this.kind = "remote";
					break;
			}
			this.provider = provider;
			this.main_context = manager.main_context;

			provider.agent_session_closed.connect (on_agent_session_closed);
		}

		public async Gee.List<Frida.HostProcessInfo?> enumerate_processes () throws Error {
			yield ensure_host_session ();
			var processes = yield host_session.enumerate_processes ();
			var result = new Gee.ArrayList<Frida.HostProcessInfo?> ();
			foreach (var process in processes) {
				result.add (process);
			}
			return result;
		}

		public Gee.List<Frida.HostProcessInfo?> enumerate_processes_sync () throws Error {
			return (create<EnumerateTask> () as EnumerateTask).start_and_wait_for_completion ();
		}

		private class EnumerateTask : DeviceTask<Gee.List<Frida.HostProcessInfo?>> {
			protected override async Gee.List<Frida.HostProcessInfo?> perform_operation () throws Error {
				return yield parent.enumerate_processes ();
			}
		}

		public async uint spawn (string path, string[] argv, string[] envp) throws Error {
			yield ensure_host_session ();
			return yield host_session.spawn (path, argv, envp);
		}

		public uint spawn_sync (string path, string[] argv, string[] envp) throws Error {
			var task = create<SpawnTask> () as SpawnTask;
			task.path = path;
			task.argv = argv;
			task.envp = envp;
			return task.start_and_wait_for_completion ();
		}

		private class SpawnTask : DeviceTask<uint> {
			public string path;
			public string[] argv;
			public string[] envp;

			protected override async uint perform_operation () throws Error {
				return yield parent.spawn (path, argv, envp);
			}
		}

		public async void resume (uint pid) throws Error {
			yield ensure_host_session ();
			yield host_session.resume (pid);
		}

		public void resume_sync (uint pid) throws Error {
			var task = create<ResumeTask> () as ResumeTask;
			task.pid = pid;
			task.start_and_wait_for_completion ();
		}

		private class ResumeTask : DeviceTask<void> {
			public uint pid;

			protected override async void perform_operation () throws Error {
				yield parent.resume (pid);
			}
		}

		public async Session attach (uint pid) throws Error {
			var session = session_by_pid[pid];
			if (session == null) {
				yield ensure_host_session ();

				var agent_session_id = yield host_session.attach_to (pid);
				var agent_session = yield provider.obtain_agent_session (agent_session_id);
				session = new Session (this, pid, agent_session);
				session_by_pid[pid] = session;
				session_by_handle[agent_session_id.handle] = session;
			}
			return session;
		}

		public Session attach_sync (uint pid) throws Error {
			var task = create<AttachTask> () as AttachTask;
			task.pid = pid;
			return task.start_and_wait_for_completion ();
		}

		private class AttachTask : DeviceTask<Session> {
			public uint pid;

			protected override async Session perform_operation () throws Error {
				return yield parent.attach (pid);
			}
		}

		public async void _do_close (bool may_block) {
			if (is_closed)
				return;
			is_closed = true;

			provider.agent_session_closed.disconnect (on_agent_session_closed);

			foreach (var session in session_by_pid.values.to_array ())
				yield session._do_close (may_block);
			session_by_pid.clear ();
			session_by_handle.clear ();

			host_session = null;

			manager._release_device (this);
			manager = null;

			closed ();
		}

		public void _release_session (Session session) {
			var session_did_exist = session_by_pid.unset (session.pid);
			assert (session_did_exist);

			uint handle = 0;
			foreach (var entry in session_by_handle.entries) {
				if (entry.value == session) {
					handle = entry.key;
					break;
				}
			}
			assert (handle != 0);
			session_by_handle.unset (handle);
		}

		private async void ensure_host_session () throws IOError {
			if (host_session == null) {
				host_session = yield provider.create ();
			}
		}

		protected void on_agent_session_closed (Frida.AgentSessionId id, Error? error) {
			var session = session_by_handle[id.handle];
			if (session != null)
				session._do_close (false);
		}

		private Object create<T> () {
			return Object.new (typeof (T), main_context: main_context, parent: this);
		}

		private abstract class DeviceTask<T> : AsyncTask<T> {
			public weak Device parent {
				get;
				construct;
			}

			protected override void validate_operation () throws Error {
				if (parent.is_closed)
					throw new IOError.FAILED ("invalid operation (device is closed)");
			}
		}
	}

	public class Session : Object {
		public signal void closed ();

		public uint pid {
			get;
			private set;
		}

		public Frida.AgentSession internal_session {
			get;
			private set;
		}

		public MainContext main_context {
			get;
			private set;
		}

		private weak Device device;
		private bool is_closed = false;

		private Gee.HashMap<uint, Script> script_by_id = new Gee.HashMap<uint, Script> ();

		public Session (Device device, uint pid, Frida.AgentSession agent_session) {
			this.device = device;
			this.pid = pid;
			this.internal_session = agent_session;
			this.main_context = device.main_context;

			internal_session.message_from_script.connect (on_message_from_script);
		}

		public async void close () {
			yield _do_close (true);
		}

		public void close_sync () {
			try {
				(create<CloseTask> () as CloseTask).start_and_wait_for_completion ();
			} catch (Error e) {
				assert_not_reached ();
			}
		}

		private class CloseTask : SessionTask<void> {
			protected override void validate_operation () throws Error {
			}

			protected override async void perform_operation () throws Error {
				yield parent.close ();
			}
		}

		public async Script create_script (string source) throws Error {
			var sid = yield internal_session.create_script (source);
			var script = new Script (this, sid);
			script_by_id[sid.handle] = script;
			return script;
		}

		public Script create_script_sync (string source) throws Error {
			var task = create<CreateScriptTask> () as CreateScriptTask;
			task.source = source;
			return task.start_and_wait_for_completion ();
		}

		private class CreateScriptTask : SessionTask<Script> {
			public string source;

			protected override async Script perform_operation () throws Error {
				return yield parent.create_script (source);
			}
		}

		private void on_message_from_script (Frida.AgentScriptId sid, string message, uint8[] data) {
			var script = script_by_id[sid.handle];
			if (script != null)
				script.message (message, data);
		}

		public void _release_script (Frida.AgentScriptId sid) {
			var script_did_exist = script_by_id.unset (sid.handle);
			assert (script_did_exist);
		}

		public async void _do_close (bool may_block) {
			if (is_closed)
				return;
			is_closed = true;

			foreach (var script in script_by_id.values.to_array ())
				yield script._do_unload (may_block);

			if (may_block) {
				try {
					yield internal_session.close ();
				} catch (IOError ignored_error) {
				}
			}
			internal_session.message_from_script.disconnect (on_message_from_script);
			internal_session = null;

			device._release_session (this);
			device = null;

			closed ();
		}

		private Object create<T> () {
			return Object.new (typeof (T), main_context: main_context, parent: this);
		}

		private abstract class SessionTask<T> : AsyncTask<T> {
			public weak Session parent {
				get;
				construct;
			}

			protected override void validate_operation () throws Error {
				if (parent.is_closed)
					throw new IOError.FAILED ("invalid operation (session is closed)");
			}
		}
	}

	public class Script : Object {
		public signal void message (string message, uint8[] data);

		public MainContext main_context {
			get;
			private set;
		}

		private weak Session session;
		private Frida.AgentScriptId script_id;

		public Script (Session session, Frida.AgentScriptId script_id) {
			this.session = session;
			this.script_id = script_id;
			this.main_context = session.main_context;
		}

		public async void load () throws Error {
			yield session.internal_session.load_script (script_id);
		}

		public void load_sync () throws Error {
			(create<LoadTask> () as LoadTask).start_and_wait_for_completion ();
		}

		private class LoadTask : ScriptTask<void> {
			protected override async void perform_operation () throws Error {
				yield parent.load ();
			}
		}

		public async void unload () throws Error {
			yield _do_unload (true);
		}

		public void unload_sync () throws Error {
			(create<UnloadTask> () as UnloadTask).start_and_wait_for_completion ();
		}

		private class UnloadTask : ScriptTask<void> {
			protected override async void perform_operation () throws Error {
				yield parent.unload ();
			}
		}

		public async void post_message (string message) throws Error {
			yield session.internal_session.post_message_to_script (script_id, message);
		}

		public void post_message_sync (string message) throws Error {
			var task = create<PostMessageTask> () as PostMessageTask;
			task.message = message;
			task.start_and_wait_for_completion ();
		}

		private class PostMessageTask : ScriptTask<void> {
			public string message;

			protected override async void perform_operation () throws Error {
				yield parent.post_message (message);
			}
		}

		public async void _do_unload (bool may_block) {
			var s = session;
			session = null;

			var sid = script_id;

			s._release_script (sid);

			if (may_block) {
				try {
					yield s.internal_session.destroy_script (sid);
				} catch (IOError ignored_error) {
				}
			}
		}

		private Object create<T> () {
			return Object.new (typeof (T), main_context: main_context, parent: this);
		}

		private abstract class ScriptTask<T> : AsyncTask<T> {
			public weak Script parent {
				get;
				construct;
			}

			protected override void validate_operation () throws Error {
				if (parent.session == null)
					throw new IOError.FAILED ("invalid operation (script is destroyed)");
			}
		}
	}

	private abstract class AsyncTask<T> : Object {
		public MainContext main_context {
			get;
			construct;
		}

		private MainLoop loop;
		private bool completed;
		private Mutex mutex = new Mutex ();
		private Cond cond = new Cond ();

		private T result;
		private Error error;

		public T start_and_wait_for_completion () throws Error {
			if (main_context.is_owner ())
				loop = new MainLoop (main_context);

			var source = new IdleSource ();
			source.set_callback (() => {
				do_perform_operation ();
				return false;
			});
			source.attach (main_context);

			if (loop != null) {
				loop.run ();
			} else {
				mutex.lock ();
				while (!completed)
					cond.wait (mutex);
				mutex.unlock ();
			}

			if (error != null)
				throw error;

			return result;
		}

		private async void do_perform_operation () {
			try {
				validate_operation ();
				result = yield perform_operation ();
			} catch (Error e) {
				error = new IOError.FAILED (e.message);
			}

			if (loop != null) {
				loop.quit ();
			} else {
				mutex.lock ();
				completed = true;
				cond.signal ();
				mutex.unlock ();
			}
		}

		protected abstract void validate_operation () throws Error;
		protected abstract async T perform_operation () throws Error;
	}
}