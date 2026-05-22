// =========================
// ROBUST SCROLL MANAGER (AUTO LAYOUT SAFE + ANIMATED RESTORE)
// =========================

function getScrollEl() {
	return document.scrollingElement || document.documentElement;
}

// SAVE
function saveScroll(key) {
	const el = getScrollEl();
	sessionStorage.setItem(key, String(el.scrollTop || 0));
}

// RESET
function resetScrollTop(key = null) {
	if (key) sessionStorage.removeItem(key);
	getScrollEl().scrollTop = 0;
}

// BIND
function bindScrollPersistence(key) {
	const el = getScrollEl();
	let scrollTimeout;

	function handleScroll() {
		clearTimeout(scrollTimeout);
		scrollTimeout = setTimeout(() => {
			saveScroll(key);
		}, 150);
	}

	window.addEventListener('scroll', handleScroll, { passive: true });
	el.addEventListener('scroll', handleScroll, { passive: true });
}

// AUTO RESTORE (via pageshow)
function enableAutoRestore(key) {
	if (sessionStorage.getItem('force_scroll_top') === '1') {
		sessionStorage.removeItem('force_scroll_top');
		resetScrollTop(key);
		return;
	}

	window.addEventListener('pageshow', (event) => {
		if (event.persisted) {
			const y = Number(sessionStorage.getItem(key) || 0);
			if (y > 0) {
				window.scrollTo(0, y);
			}
		}
	});
}
