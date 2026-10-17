const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

// Keep playback intent separate from browser-generated pause events. Safari
// can pause media at an end boundary or while its page is offscreen.
function setupLoopingVideo({ video, toggle, label, region, name, shortName, nativeControls }) {
  let wantsPlayback = !reducedMotion.matches;
  let visible = false;
  let automaticPause = false;
  let playPending = false;

  video.defaultMuted = true;
  video.muted = true;
  video.playsInline = true;
  video.loop = true;
  if (reducedMotion.matches) {
    video.autoplay = false;
    video.pause();
  }

  function updateControl() {
    const paused = video.paused;
    toggle.setAttribute('aria-pressed', String(paused));
    toggle.setAttribute('aria-label', `${paused ? 'Play' : 'Pause'} ${name}`);
    label.textContent = `${paused ? 'Play' : 'Pause'} ${shortName}`;
  }
  function shouldPlay() { return wantsPlayback && visible && !document.hidden; }
  function atEnd() {
    return video.ended || (Number.isFinite(video.duration) && video.duration > 0 && video.currentTime >= video.duration - .08);
  }
  function syncPlayback() {
    if (!shouldPlay()) {
      if (!video.paused) {
        automaticPause = true;
        video.pause();
      }
    } else if (video.paused && !playPending) {
      if (atEnd()) video.currentTime = 0;
      playPending = true;
      // A blocked autoplay attempt leaves a working, accurately labeled button.
      video.play().catch(() => {}).finally(() => {
        playPending = false;
        if (!shouldPlay() && !video.paused) syncPlayback();
        updateControl();
      });
    }
    updateControl();
  }
  function restartLoop() {
    if (!shouldPlay()) return;
    video.currentTime = 0;
    syncPlayback();
  }

  video.addEventListener('play', () => {
    if (nativeControls) wantsPlayback = true;
    updateControl();
  });
  video.addEventListener('pause', () => {
    if (automaticPause) automaticPause = false;
    else if (atEnd()) restartLoop();
    else if (nativeControls && visible && !document.hidden) wantsPlayback = false;
    updateControl();
  });
  // Native loop is the normal path. These cover WebKit end-boundary pauses.
  video.addEventListener('ended', restartLoop);
  video.addEventListener('timeupdate', () => {
    if (video.paused && atEnd()) restartLoop();
  });
  video.addEventListener('loadeddata', syncPlayback);
  toggle.addEventListener('click', () => {
    wantsPlayback = video.paused;
    const rect = region.getBoundingClientRect();
    visible = rect.bottom > 0 && rect.top < window.innerHeight;
    syncPlayback();
  });
  reducedMotion.addEventListener('change', event => {
    wantsPlayback = !event.matches;
    syncPlayback();
  });
  document.addEventListener('visibilitychange', syncPlayback);
  window.addEventListener('pageshow', syncPlayback);
  new IntersectionObserver(entries => {
    visible = entries[0].isIntersecting;
    syncPlayback();
  }, { threshold: .03 }).observe(region);
  updateControl();
}

setupLoopingVideo({
  video: document.getElementById('hero-video'),
  toggle: document.getElementById('scene-toggle'),
  label: document.querySelector('.scene-label'),
  region: document.querySelector('.hero'),
  name: 'background animation', shortName: 'scene', nativeControls: false
});
setupLoopingVideo({
  video: document.getElementById('demo-video'),
  toggle: document.getElementById('demo-toggle'),
  label: document.querySelector('.demo-toggle-label'),
  region: document.getElementById('demo-video'),
  name: 'app demo', shortName: 'demo', nativeControls: true
});

const copyButton = document.getElementById('copy-command');
const copyLabel = copyButton.querySelector('.copy-label');
const copyStatus = document.getElementById('copy-status');
let copyTimeout;
copyButton.addEventListener('click', async () => {
  const command = document.getElementById('install-code').textContent;
  try {
    await navigator.clipboard.writeText(command);
    copyLabel.textContent = 'Copied';
    copyButton.setAttribute('aria-label', 'Install command copied');
    copyStatus.textContent = 'Copied. Paste it into your terminal.';
  } catch {
    const selection = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents(document.getElementById('install-code'));
    selection.removeAllRanges(); selection.addRange(range);
    copyStatus.textContent = 'Command selected. Use your device’s copy action.';
  }
  clearTimeout(copyTimeout);
  copyTimeout = setTimeout(() => { copyLabel.textContent = 'Copy'; copyButton.setAttribute('aria-label', 'Copy Homebrew install command'); copyStatus.textContent = ''; }, 5000);
});
