function filterRows(query) {
	const input = document.getElementById('smsSentSearch');
	if (!query) query = input.value.toLowerCase();

	const table = document.getElementById('sms_table');
	const rows = table.querySelectorAll('tbody tr');

	rows.forEach(row => {
		const text = row.innerText.toLowerCase();
		const matchesSearch = text.includes(query);
		row.style.display = matchesSearch ? '' : 'none';
	});

	// Re-apply zebra striping ONLY on visible rows
	const visibleRows = Array.from(rows).filter(row => row.style.display !== 'none');

	visibleRows.forEach((row, index) => {
		row.style.background = (index % 2 === 0) ? '#FFF' : '#EEE';
	});

	// ❌ REMOVED: window.scrollTo(0, 0);
	// (this was breaking scroll restoration system)
}

document.addEventListener('DOMContentLoaded', function () {
	const input = document.getElementById('smsSentSearch');

	let refreshTimeout;

	// =========================
	// AUTO REFRESH LOOP
	// =========================

	function scheduleRefresh() {
		refreshTimeout = setTimeout(async () => {
			const query = input.value.toLowerCase();

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
			e.preventDefault();
			input.focus();
		}
	});

	// =========================
	// INIT
	// =========================

	input.focus();
	scheduleRefresh();
});
