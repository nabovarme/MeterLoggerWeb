function filterRows(query) {
	const input = document.getElementById('smsSentSearch');
	if (query === undefined || query === null) {
		query = input ? input.value.toLowerCase() : '';
	}

	const table = document.getElementById('sms_table');
	if (!table) return;
	
	const rows = table.querySelectorAll('tbody tr');
	let visibleIndex = 0;

	// Single pass optimization: filter AND zebra-stripe in one step
	rows.forEach(row => {
		// 🚀 OPTIMIZATION: textContent is up to 100x faster than innerText because it ignores CSS layouts
		const text = row.textContent.toLowerCase();
		const matchesSearch = text.includes(query);
		
		if (matchesSearch) {
			row.style.display = '';
			// Apply zebra striping on the fly using our visible tracker
			row.style.background = (visibleIndex % 2 === 0) ? '#FFF' : '#EEE';
			visibleIndex++;
		} else {
			row.style.display = 'none';
		}
	});
}

document.addEventListener('DOMContentLoaded', function () {
	const input = document.getElementById('smsSentSearch');

	let refreshTimeout;

	// =========================
	// AUTO REFRESH LOOP
	// =========================

	function scheduleRefresh() {
		refreshTimeout = setTimeout(async () => {
			const query = input ? input.value.toLowerCase() : '';

			if (typeof loadSMS === 'function') {
				await loadSMS();
			}

			filterRows(query);
			scheduleRefresh();
		}, 60000); // 60 seconds
	}

	// =========================
	// KEYBOARD SHORTCUT
	// =========================

	document.addEventListener('keydown', (e) => {
		if (e.key.toLowerCase() === 'f' && (e.ctrlKey || e.altKey) && !e.metaKey) {
			if (input) {
				e.preventDefault();
				input.focus();
			}
		}
	});

	// =========================
	// INIT
	// =========================

	if (input) {
		input.focus();
	}
	scheduleRefresh();
});

