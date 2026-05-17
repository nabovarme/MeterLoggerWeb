// =========================
// ROBUST SCROLL MANAGER (AUTO LAYOUT SAFE)
// =========================

function getScrollEl() {
	return document.scrollingElement || document.documentElement;
}

// =========================
// SAVE
// =========================

function saveScroll(key) {
	const el = getScrollEl();
	sessionStorage.setItem(key, String(el.scrollTop || 0));
}

// =========================
// RESET
// =========================

function resetScrollTop(key = null) {
	if (key) sessionStorage.removeItem(key);
	getScrollEl().scrollTop = 0;
}

// =========================
// INTERNAL: WAIT FOR LAYOUT STABLE
// =========================

function waitForLayoutStable(callback) {
	let lastHeight = document.body.scrollHeight;
	let stableCount = 0;

	function check() {
		const h = document.body.scrollHeight;

		if (h === lastHeight) {
			stableCount++;
		} else {
			stableCount = 0;
			lastHeight = h;
		}

		if (stableCount >= 2) {
			callback();
		} else {
			requestAnimationFrame(check);
		}
	}

	requestAnimationFrame(check);
}

// =========================
// RESTORE (AUTO SAFE)
// =========================

function restoreScroll(key) {
	const y = Number(sessionStorage.getItem(key) || 0);
	const el = getScrollEl();

	requestAnimationFrame(() => {
		requestAnimationFrame(() => {
			waitForLayoutStable(() => {
				setTimeout(() => {
					el.scrollTop = y;
					document.documentElement.scrollTop = y;
					document.body.scrollTop = y;
				}, 30);
			});
		});
	});
}

// =========================
// BIND
// =========================

function bindScrollPersistence(key) {
	const el = getScrollEl();

	window.addEventListener('scroll', () => {
		saveScroll(key);
	}, { passive: true });

	el.addEventListener('scroll', () => {
		saveScroll(key);
	}, { passive: true });

	window.addEventListener('pagehide', () => {
		saveScroll(key);
	});
}

// =========================
// AUTO RESTORE
// =========================

function enableAutoRestore(key) {

	// navigation from menu -> always start at top
	if (sessionStorage.getItem('force_scroll_top') === '1') {

		sessionStorage.removeItem('force_scroll_top');

		requestAnimationFrame(() => {
			resetScrollTop(key);
		});

		return;
	}

	window.addEventListener('pageshow', (event) => {

		if (event.persisted) {
			restoreScroll(key);

		} else {

			// normal reload case
			requestAnimationFrame(() => {
				requestAnimationFrame(() => {

					waitForLayoutStable(() => {

						setTimeout(() => {
							restoreScroll(key);
						}, 50);
					});
				});
			});
		}
	});
}
