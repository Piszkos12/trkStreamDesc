/*
  nowplaying.js - shared WebSocket client of the trkStreamDesc overlays.

  URL parameters of the overlay page:
    ?hide=20                 hide the overlay 20 s after a track change (0 = always visible)
    ?ws=ws://host:port/ws    server address, needed only when the page is not
                             loaded from the trkStreamDesc server (e.g. file://)
    ?demo                    no server: cycles through sample tracks (for previews)

  Until the first track arrives the overlay shows a "warm-up" placeholder
  track (track.idle === true), so it is never an empty picture.

  Usage:
    NowPlaying.start({
      onTrack(track, previous) { ... },  // a new track became current
      onSource(live) { ... },            // Traktor connected / disconnected
      onMessage(msg) { ... }             // any other message (e.g. request replies)
    });
*/
const NowPlaying = (() => {
  const params = new URLSearchParams(location.search);
  const hideAfter = Number(params.get('hide') || 0);
  const wsUrl = params.get('ws') || `ws://${location.host || 'localhost'}/ws`;
  const demo = params.has('demo');
  const RECONNECT_MS = 2000;
  const DEMO_INTERVAL_MS = 8000;
  const DEMO_TRACKS = [
    { artist: 'Daft Punk', title: 'One More Time', album: 'Discovery', genre: 'House', year: '2000', tags: { bpm: '123' } },
    { artist: 'Justice', title: 'D.A.N.C.E.', album: '†', genre: 'Electro', year: '2007', tags: { bpm: '113' } },
    { artist: 'Fred again..', title: 'Delilah (pull me out of this) – Extended Mix', album: 'Actual Life 3', genre: 'Electronic', year: '2022', tags: {} },
  ];
  const IDLE_TRACK = {
    idle: true, artist: 'Waiting for the first track', title: 'Warming up…',
    album: '', genre: '', year: '', tags: {},
  };
  let history = [];  // demo mode only, newest first

  let clockOffset = 0;  // server clock minus local clock, in ms
  let current = null;   // current track object as sent by the server
  let socket = null;

  /** Seconds since the current track started (by the server's clock). */
  function elapsed() {
    if (!current || current.idle) return 0;
    return Math.max(0, Math.floor((Date.now() + clockOffset - current.started) / 1000));
  }

  /** 125 -> "2:05" */
  function formatTime(seconds) {
    return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
  }

  let handleMessage = () => {};

  /** Sends a request object; returns false while disconnected. */
  function send(request) {
    if (demo) {
      // answer the only request the overlays use without a server
      if (request.cmd === 'history') {
        const items = history.slice(0, request.limit || history.length);
        setTimeout(() => handleMessage({ type: 'history', items, id: request.id }), 0);
      }
      return true;
    }
    if (!socket || socket.readyState !== WebSocket.OPEN) return false;
    socket.send(JSON.stringify(request));
    return true;
  }

  function start(handlers) {
    const { onTrack = () => {}, onSource = () => {}, onMessage = () => {} } = handlers;
    handleMessage = onMessage;

    function nextDemoTrack(index) {
      if (!current.idle) history.unshift(current);
      const previous = current;
      current = { ...DEMO_TRACKS[index % DEMO_TRACKS.length], started: Date.now() };
      onTrack(current, previous);
      setTimeout(() => nextDemoTrack(index + 1), DEMO_INTERVAL_MS);
    }

    function connect() {
      socket = new WebSocket(wsUrl);
      socket.onmessage = (event) => {
        const msg = JSON.parse(event.data);
        if (msg.serverTime) clockOffset = msg.serverTime - Date.now();
        if ('source' in msg) onSource(msg.source);

        // "hello", "now" and "track" all carry the current track; the start
        // time identifies it, so reconnects do not replay the animation
        if (msg.track && (current.idle || msg.track.started !== current.started)) {
          const previous = current;
          current = msg.track;
          onTrack(current, previous);
        } else if (!msg.track) {
          onMessage(msg);
        }
      };
      socket.onclose = () => setTimeout(connect, RECONNECT_MS);
    }

    // warm-up picture until the first real track
    current = { ...IDLE_TRACK, started: Date.now() };
    onTrack(current, null);

    if (demo) {
      onSource(true);
      setTimeout(() => nextDemoTrack(0), DEMO_INTERVAL_MS / 2);
    } else {
      connect();
    }
  }

  /** Shrinks the font of a single-line element (white-space: nowrap) until its
      text fits, but not below minPx; CSS ellipsis can handle the rest. */
  function fitText(el, minPx) {
    el.style.fontSize = '';
    let size = parseFloat(getComputedStyle(el).fontSize);
    while (el.scrollWidth > el.clientWidth && size > minPx) {
      size -= 2;
      el.style.fontSize = `${size}px`;
    }
  }

  let hideTimer = null;

  /** Calls hide() hideAfter seconds after the last call (no-op without ?hide). */
  function autoHide(hide) {
    clearTimeout(hideTimer);
    if (hideAfter > 0) hideTimer = setTimeout(hide, hideAfter * 1000);
  }

  return {
    hideAfter,
    start,
    send,
    elapsed,
    formatTime,
    fitText,
    autoHide,
    get track() { return current; },
  };
})();
