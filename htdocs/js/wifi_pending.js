let wifiDebounceTimeout = null;
let isInitialLoad = true;

function getScrollY() {
	return window.scrollY || document.documentElement.scrollTop;
}

// =========================
// SCROLL PERSISTENCE
// =========================

function saveScroll() {
	const params = new URLSearchParams(window.location.search);
	const hasFilter = params.get('q');

	if (hasFilter) {
		sessionStorage.setItem('wifi_scroll', getScrollY());
	}
}

function restoreScroll() {
	const y = Number(sessionStorage.getItem('wifi_scroll') || 0);

	requestAnimationFrame(() => {
		window.scrollTo(0, y);
	});
}

window.addEventListener('scroll', saveScroll, { passive: true });
window.addEventListener('beforeunload', saveScroll);

// =========================
// LOAD WIFI
// =========================

async function loadWifi() {
	try {
		const resp = await fetch('/api/wifi_pending');
		if (!resp.ok) throw new Error(`HTTP error! status: ${resp.status}`);
		const data = await resp.json();

		const tbody = document.querySelector('#wifi_table tbody');
		tbody.innerHTML = ''; // clear existing rows

		// =========================
		// URL STATE (READ)
		// =========================
		const params = new URLSearchParams(window.location.search);
		const search = (params.get('q') || '').toLowerCase();

		for (const row of data) {

			// filter by search (serial + info + ssid)
			if (search) {
				const text = `${row.serial || ''} ${row.info || ''} ${row.ssid || ''}`.toLowerCase();
				if (!text.includes(search)) continue;
			}

			const tr = document.createElement('tr');
			tr.align = 'left';
			tr.valign = 'top';

			tr.innerHTML = `
				<td align="left">
					<a href="detail_acc.epl?serial=${encodeURIComponent(row.serial || '')}">
						<span class="default">${row.serial}</span>
					</a>
				</td>
				<td>&nbsp;</td>
				<td align="left"><span class="default">${row.info}</span></td>
				<td>&nbsp;</td>
				<td align="left"><span class="default">${row.ssid}</span></td>
				<td>&nbsp;</td>
				<td align="left"><span class="default">${row.time}</span></td>
			`;

			tbody.appendChild(tr);
		}

		// =========================
		// SCROLL RESTORE LOGIC
		// =========================

		const isResetState = !search;

		if (isResetState && !isInitialLoad) {
			sessionStorage.removeItem('wifi_scroll');
			window.scrollTo(0, 0);
		}

		requestAnimationFrame(() => {
			requestAnimationFrame(() => {
				if (isInitialLoad) {
					restoreScroll();
					isInitialLoad = false;
				}
			});
		});

	} catch (err) {
		console.error('Failed to load wifi:', err);
	}
}

// =========================
// URL UPDATE
// =========================

function updateURL(value) {
	const p = new URLSearchParams(window.location.search);

	if (value) p.set('q', value);
	else p.delete('q');

	const newUrl = `${window.location.pathname}?${p.toString()}`;

	history.replaceState({}, '', newUrl);
}

// =========================
// DEBOUNCED RELOAD
// =========================

function reloadWifiDebounced() {
	clearTimeout(wifiDebounceTimeout);

	wifiDebounceTimeout = setTimeout(() => {
		loadWifi();
	}, 300);
}

// =========================
// INPUT BINDING
// =========================

const wifiInput = document.getElementById('wifiPendingSearch');

if (wifiInput) {
	// restore from URL
	const params = new URLSearchParams(window.location.search);
	wifiInput.value = params.get('q') || '';

	wifiInput.addEventListener('input', () => {
		const val = wifiInput.value;

		updateURL(val);
		reloadWifiDebounced();

		// reset scroll immediately on any change
		sessionStorage.removeItem('wifi_scroll');
		window.scrollTo(0, 0);
	});
}

// =========================
// INIT
// =========================

loadWifi();
