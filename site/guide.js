const guideStatus = document.getElementById('guide-copy-status');
const copyTimers = new WeakMap();
document.querySelectorAll('[data-copy-target]').forEach(button => {
  button.addEventListener('click', async () => {
    const code = document.getElementById(button.dataset.copyTarget);
    try {
      await navigator.clipboard.writeText(code.textContent);
      button.textContent = 'Copied';
      button.dataset.copied = 'true';
      guideStatus.textContent = 'Commands copied to clipboard.';
    } catch {
      const range = document.createRange();
      range.selectNodeContents(code);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      guideStatus.textContent = 'Commands selected. Use your device’s copy action.';
    }
    clearTimeout(copyTimers.get(button));
    copyTimers.set(button, setTimeout(() => {
      button.textContent = 'Copy';
      delete button.dataset.copied;
      guideStatus.textContent = '';
    }, 3500));
  });
});
const guideLinks = [...document.querySelectorAll('.guide-sidebar nav a')];
const guideSections = [...document.querySelectorAll('.guide-section')];
function markGuideSection(id) {
  guideLinks.forEach(link => {
    if (link.hash === `#${id}`) link.setAttribute('aria-current', 'location');
    else link.removeAttribute('aria-current');
  });
}
guideLinks.forEach(link => link.addEventListener('click', () => markGuideSection(link.hash.slice(1))));
const guideObserver = new IntersectionObserver(entries => {
  const visible = entries.filter(entry => entry.isIntersecting).sort((a,b) => a.boundingClientRect.top - b.boundingClientRect.top);
  if (visible.length) markGuideSection(visible[0].target.id);
}, { rootMargin: '-12% 0px -58% 0px', threshold: 0 });
guideSections.forEach(section => guideObserver.observe(section));
