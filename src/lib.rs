use std::{
    collections::HashSet,
    io,
    path::PathBuf,
    sync::{
        mpsc::{Receiver, RecvTimeoutError, TryRecvError},
        Arc, Mutex,
    },
    time::Duration,
};

use abi_stable::std_types::{RBoxError, RResult, RString, RVec};
use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use steel::{
    rvals::Custom,
    steel_vm::ffi::{FFIModule, FFIValue, IntoFFIVal, RegisterFFIFn},
};

steel::declare_module!(build_module);

const EVENT_BATCH_DEBOUNCE: Duration = Duration::from_millis(50);

fn file_watcher_module() -> FFIModule {
    let mut module = FFIModule::new("steel/file-watcher");

    module
        .register_fn("watch-recursive", watch_recursive)
        .register_fn("watch-file-list", watch_file_list)
        .register_fn("receive-event!", EventReceiver::recv)
        .register_fn("receive-event-timeout!", EventReceiver::recv_timeout)
        .register_fn("receive-paths!", EventReceiver::recv_paths)
        .register_fn("receive-paths-timeout!", EventReceiver::recv_paths_timeout)
        .register_fn("event-paths", NotifyEvent::paths)
        .register_fn("event-kind", NotifyEvent::kind)
        .register_fn("make-empty-watcher", spawn_empty_watcher)
        .register_fn("watch-controller", EventReceiver::controller)
        .register_fn("watch-file!", WatchController::watch_file)
        .register_fn("set-watched-files!", WatchController::set_watched_files)
        .register_fn("unwatch-file!", WatchController::unwatch_file);

    module
}

struct EventReceiver {
    inner: Arc<WatcherInner>,
}

struct WatchController {
    inner: Arc<WatcherInner>,
}

struct WatcherInner {
    watcher: Mutex<RecommendedWatcher>,
    receiver: Mutex<Receiver<Event>>,
    watched_paths: Arc<Mutex<HashSet<PathBuf>>>,
    watched_dirs: Mutex<HashSet<PathBuf>>,
}

struct NotifyEvent(Event);

impl Custom for EventReceiver {}
impl Custom for WatchController {}
impl Custom for NotifyEvent {}

impl EventReceiver {
    fn controller(&self) -> FFIValue {
        WatchController {
            inner: Arc::clone(&self.inner),
        }
        .into_ffi_val()
        .unwrap()
    }

    fn recv(&self) -> RResult<FFIValue, RBoxError> {
        let res = self
            .inner
            .receiver
            .lock()
            .unwrap()
            .recv()
            .map(NotifyEvent)
            .map(|x| x.into_ffi_val().unwrap())
            .map_err(|x| RBoxError::new(x));

        match res {
            Ok(ok) => RResult::ROk(ok),
            Err(err) => RResult::RErr(err),
        }
    }

    fn recv_timeout(&self, timeout_ms: usize) -> RResult<FFIValue, RBoxError> {
        let res = self
            .inner
            .receiver
            .lock()
            .unwrap()
            .recv_timeout(Duration::from_millis(timeout_ms as u64))
            .map(NotifyEvent)
            .map(|x| x.into_ffi_val().unwrap());

        match res {
            Ok(ok) => RResult::ROk(ok),
            Err(RecvTimeoutError::Timeout) => RResult::ROk(FFIValue::BoolV(false)),
            Err(RecvTimeoutError::Disconnected) => RResult::RErr(RBoxError::new(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "file watcher event channel disconnected",
            ))),
        }
    }

    fn recv_paths(&self) -> RResult<FFIValue, RBoxError> {
        let receiver = self.inner.receiver.lock().unwrap();
        let first = match receiver.recv() {
            Ok(event) => event,
            Err(_) => {
                return RResult::RErr(RBoxError::new(io::Error::new(
                    io::ErrorKind::BrokenPipe,
                    "file watcher event channel disconnected",
                )));
            }
        };

        self.collect_paths_from(first, &receiver)
    }

    fn recv_paths_timeout(&self, timeout_ms: usize) -> RResult<FFIValue, RBoxError> {
        let receiver = self.inner.receiver.lock().unwrap();
        let first = match receiver.recv_timeout(Duration::from_millis(timeout_ms as u64)) {
            Ok(event) => event,
            Err(RecvTimeoutError::Timeout) => return RResult::ROk(FFIValue::BoolV(false)),
            Err(RecvTimeoutError::Disconnected) => {
                return RResult::RErr(RBoxError::new(io::Error::new(
                    io::ErrorKind::BrokenPipe,
                    "file watcher event channel disconnected",
                )));
            }
        };

        self.collect_paths_from(first, &receiver)
    }

    fn collect_paths_from(
        &self,
        first: Event,
        receiver: &Receiver<Event>,
    ) -> RResult<FFIValue, RBoxError> {
        let mut paths = HashSet::new();
        collect_event_paths(first, &mut paths);

        std::thread::sleep(EVENT_BATCH_DEBOUNCE);

        loop {
            match receiver.try_recv() {
                Ok(event) => collect_event_paths(event, &mut paths),
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    return RResult::RErr(RBoxError::new(io::Error::new(
                        io::ErrorKind::BrokenPipe,
                        "file watcher event channel disconnected",
                    )));
                }
            }
        }

        let paths: RVec<FFIValue> = paths
            .into_iter()
            .filter_map(|path| path.into_os_string().into_string().ok())
            .map(|path| FFIValue::StringV(RString::from(path)))
            .collect();

        RResult::ROk(paths.into_ffi_val().unwrap())
    }
}

impl WatchController {
    fn watch_file(&self, path: &str) -> RResult<FFIValue, RBoxError> {
        let path = canonicalize_or_path(path);
        match self.watch_path(path) {
            Ok(()) => RResult::ROk(FFIValue::BoolV(true)),
            Err(err) => RResult::RErr(RBoxError::new(err)),
        }
    }

    fn unwatch_file(&self, path: &str) -> RResult<FFIValue, RBoxError> {
        let path = canonicalize_or_path(path);
        let mut watched_paths = self.inner.watched_paths.lock().unwrap();
        watched_paths.remove(&path);
        drop(watched_paths);
        match self.reconcile_watched_dirs() {
            Ok(()) => RResult::ROk(FFIValue::BoolV(true)),
            Err(err) => RResult::RErr(RBoxError::new(err)),
        }
    }

    fn set_watched_files(&self, paths: Vec<String>) -> RResult<FFIValue, RBoxError> {
        let next_paths: HashSet<PathBuf> = paths
            .iter()
            .map(|path| canonicalize_or_path(path))
            .collect();
        {
            let mut watched_paths = self.inner.watched_paths.lock().unwrap();
            *watched_paths = next_paths;
        }
        match self.reconcile_watched_dirs() {
            Ok(()) => RResult::ROk(FFIValue::BoolV(true)),
            Err(err) => RResult::RErr(RBoxError::new(err)),
        }
    }

    fn watch_path(&self, path: PathBuf) -> notify::Result<()> {
        {
            let mut watched_paths = self.inner.watched_paths.lock().unwrap();
            watched_paths.insert(path);
        }
        self.reconcile_watched_dirs()
    }

    fn reconcile_watched_dirs(&self) -> notify::Result<()> {
        let next_dirs: HashSet<PathBuf> = self
            .inner
            .watched_paths
            .lock()
            .unwrap()
            .iter()
            .filter_map(|path| path.parent().map(PathBuf::from))
            .collect();

        let mut watched_dirs = self.inner.watched_dirs.lock().unwrap();
        let mut watcher = self.inner.watcher.lock().unwrap();

        for dir in next_dirs.difference(&watched_dirs) {
            watcher.watch(dir, RecursiveMode::NonRecursive)?;
        }

        for dir in watched_dirs.difference(&next_dirs) {
            watcher.unwatch(dir)?;
        }

        *watched_dirs = next_dirs;
        Ok(())
    }
}

fn collect_event_paths(event: Event, paths: &mut HashSet<PathBuf>) {
    paths.extend(event.paths.into_iter().filter_map(|path| {
        if path.exists() {
            path.canonicalize().ok()
        } else {
            Some(path)
        }
    }));
}

impl NotifyEvent {
    pub fn kind(&self) -> FFIValue {
        match self.0.kind {
            // notify::EventKind::Any => todo!(),
            // notify::EventKind::Access(access_kind) => todo!(),
            // notify::EventKind::Create(create_kind) => todo!(),
            notify::EventKind::Modify(_) => FFIValue::StringV(RString::from("modified")),
            // notify::EventKind::Remove(remove_kind) => todo!(),
            // notify::EventKind::Other => todo!(),
            _ => FFIValue::BoolV(false),
        }
    }

    pub fn paths(&self) -> RVec<FFIValue> {
        self.0
            .paths
            .iter()
            .map(|x| FFIValue::StringV(RString::from(x.as_os_str().to_str().unwrap())))
            .collect()
    }
}

fn spawn_empty_watcher() -> FFIValue {
    let (sender, receiver) = std::sync::mpsc::channel();
    let watched_paths = Arc::new(Mutex::new(HashSet::new()));
    let watched_paths_for_events = Arc::clone(&watched_paths);

    let watcher = notify::recommended_watcher(move |event: Result<Event, _>| {
        if let Ok(mut event) = event {
            if is_reload_event(&event)
                && retain_watched_paths(&mut event, &watched_paths_for_events.lock().unwrap())
            {
                let _ = sender.send(event);
            }
        }
    })
    .unwrap();

    EventReceiver {
        inner: Arc::new(WatcherInner {
            watcher: Mutex::new(watcher),
            receiver: Mutex::new(receiver),
            watched_paths,
            watched_dirs: Mutex::new(HashSet::new()),
        }),
    }
    .into_ffi_val()
    .unwrap()
}

fn watch_recursive(path: String) -> FFIValue {
    let (sender, receiver) = std::sync::mpsc::channel();

    let mut watcher = notify::recommended_watcher(move |event: Result<Event, _>| {
        if let Ok(event) = event {
            if is_reload_event(&event) {
                let _ = sender.send(event);
            }
        }
    })
    .unwrap();

    let path = PathBuf::from(path.clone());

    watcher.watch(&path, RecursiveMode::Recursive).unwrap();

    EventReceiver {
        inner: Arc::new(WatcherInner {
            watcher: Mutex::new(watcher),
            receiver: Mutex::new(receiver),
            watched_paths: Arc::new(Mutex::new(HashSet::new())),
            watched_dirs: Mutex::new(HashSet::new()),
        }),
    }
    .into_ffi_val()
    .unwrap()
}

fn watch_file_list(paths: Vec<String>) -> FFIValue {
    let (sender, receiver) = std::sync::mpsc::channel();
    let watched_paths: HashSet<PathBuf> = paths
        .iter()
        .map(|path| canonicalize_or_path(path))
        .collect();
    let watched_paths = Arc::new(Mutex::new(watched_paths));
    let watched_paths_for_events = Arc::clone(&watched_paths);

    let mut watcher = notify::recommended_watcher(move |event: Result<Event, _>| {
        if let Ok(mut event) = event {
            if is_reload_event(&event)
                && retain_watched_paths(&mut event, &watched_paths_for_events.lock().unwrap())
            {
                let _ = sender.send(event);
            }
        }
    })
    .unwrap();

    let mut watched_dirs = HashSet::new();
    for path in watched_paths.lock().unwrap().iter() {
        if let Some(parent) = path.parent() {
            if watched_dirs.insert(parent.to_path_buf()) {
                watcher.watch(parent, RecursiveMode::NonRecursive).unwrap();
            }
        }
    }

    EventReceiver {
        inner: Arc::new(WatcherInner {
            watcher: Mutex::new(watcher),
            receiver: Mutex::new(receiver),
            watched_paths,
            watched_dirs: Mutex::new(watched_dirs),
        }),
    }
    .into_ffi_val()
    .unwrap()
}

fn is_reload_event(event: &Event) -> bool {
    matches!(
        event.kind,
        notify::EventKind::Create(_) | notify::EventKind::Modify(_)
    )
}

fn retain_watched_paths(event: &mut Event, watched_paths: &HashSet<PathBuf>) -> bool {
    event.paths.retain(|path| {
        watched_paths.contains(path) || canonicalized_is_watched(path, watched_paths)
    });
    !event.paths.is_empty()
}

fn canonicalized_is_watched(path: &PathBuf, watched_paths: &HashSet<PathBuf>) -> bool {
    match path.canonicalize() {
        Ok(path) => watched_paths.contains(&path),
        Err(_) => false,
    }
}

fn canonicalize_or_path(path: &str) -> PathBuf {
    let path = PathBuf::from(path);
    path.canonicalize().unwrap_or(path)
}

pub fn build_module() -> FFIModule {
    file_watcher_module()
}
