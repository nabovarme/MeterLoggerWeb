let wifiDebounceTimeout = null;

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
		// SCROLL RESTORE (AFTER FULL RENDER)
		// =========================
		const savedScroll = history.state?.scrollY ?? sessionStorage.getItem('wifiScrollY') ?? 0;

		requestAnimationFrame(() => {
			requestAnimationFrame(() => {
				window.scrollTo(0, Number(savedScroll));
			});
		});

	} catch (err) {
		console.error('Failed to load wifi:', err);
	}
}

// =========================
// SCROLL PERSISTENCE
// =========================

window.addEventListener('scroll', () => {
	const p = new URLSearchParams(window.location.search);

	history.replaceState(
		{
			scrollY: window.scrollY
		},
		'',
		`${window.location.pathname}?${p.toString()}`
	);
});

window.addEventListener('beforeunload', () => {
	sessionStorage.setItem('wifiScrollY', window.scrollY);
});

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
// EVENT BINDING (DIRECT)
// =========================

const wifiInput = document.getElementById('wifiPendingSearch');

if (wifiInput) {
	// restore from URL
	const params = new URLSearchParams(window.location.search);
	wifiInput.value = params.get('q') || '';

	wifiInput.addEventListener('input', () => {
		const val = wifiInput.value;

		// update URL
		const p = new URLSearchParams(window.location.search);

		if (val) p.set('q', val);
		else p.delete('q');

		const newUrl = `${window.location.pathname}?${p.toString()}`;

		history.replaceState(
			{
				scrollY: window.scrollY
			},
			'',
			newUrl
		);

		// debounce reload
		reloadWifiDebounced();
	});
}

// Initial load
loadWifi();
