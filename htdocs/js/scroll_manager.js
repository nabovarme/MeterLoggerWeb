// =========================
// ROBUST SCROLL MANAGER (AUTO LAYOUT SAFE + ANIMATED RESTORE)
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
// ANIMATED SCROLL
// =========================

function animateScrollTo(targetY, duration = 90) {
	const el = getScrollEl();

	const startY = el.scrollTop || 0;
	const diff = targetY - startY;
	const startTime = performance.now();

	function easeOut(t) {
		return 1 - Math.pow(1 - t, 4);
	}

	function step(now) {
		const elapsed = now - startTime;
		const progress = Math.min(elapsed / duration, 1);

		const value = startY + diff * easeOut(progress);

		el.scrollTop = value;
		document.documentElement.scrollTop = value;
		document.body.scrollTop = value;

		if (progress < 1) {
			requestAnimationFrame(step);
		}
	}

	requestAnimationFrame(step);
}

// =========================
// RESTORE (AUTO SAFE + ANIMATED)
// =========================

function restoreScroll(key) {
	const y = Number(sessionStorage.getItem(key) || 0);

	const el = getScrollEl();

	requestAnimationFrame(() => {
		requestAnimationFrame(() => {
			waitForLayoutStable(() => {
				setTimeout(() => {
					animateScrollTo(y, 500);
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
	// optional: prevent restoring scroll when explicitly forced to top
	if (sessionStorage.getItem('force_scroll_top') === '1') {
		sessionStorage.removeItem('force_scroll_top');

		requestAnimationFrame(() => {
			resetScrollTop(key);
		});

		return;
	}

	// hide content initially to prevent flicker
	document.body.classList.add('scroll-hidden');

	window.addEventListener('pageshow', (event) => {
		if (event.persisted) {
			restoreScroll(key);
		} else {
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

	// reveal after scroll is naturally restored/animated
	const observer = new MutationObserver(() => {
		// safety fallback: reveal if something goes wrong
		document.body.classList.remove('scroll-hidden');
		document.body.classList.add('scroll-ready');
	});

	setTimeout(() => {
		observer.disconnect();
	}, 3000);
}
