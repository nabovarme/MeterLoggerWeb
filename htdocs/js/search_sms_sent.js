// --- Global filtering function ---
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

	// Update row colors for visible rows
	const visibleRows = Array.from(rows).filter(row => row.style.display !== 'none');
	visibleRows.forEach((row, index) => {
		row.style.background = (index % 2 === 0) ? '#FFF' : '#EEE';
	});

	// Optional: scroll to top after filtering
	window.scrollTo(0, 0);
}

document.addEventListener('DOMContentLoaded', function () {
	const input = document.getElementById('smsSentSearch');
	const table = document.getElementById('sms_table');
	let debounceTimeout;
	let refreshTimeout;

	// --- Refresh logic ---
	function scheduleRefresh() {
		refreshTimeout = setTimeout(async () => {
			const query = input.value.toLowerCase();

			// Reload table data
			if (typeof loadSMS === 'function') {
				await loadSMS();
			}

			// Re-apply filter after reload
			filterRows(query);

			// Schedule next refresh
			scheduleRefresh();
		}, 60000); // refresh every 60 seconds
	}

	// --- Debounced input handler ---
	input.addEventListener('input', () => {
		clearTimeout(debounceTimeout);
		debounceTimeout = setTimeout(() => {
			filterRows();
		}, 300);
	});

	// --- Ctrl+F / Alt+F shortcut to focus search ---
	document.addEventListener('keydown', (e) => {
		if (e.key.toLowerCase() === 'f' && (e.ctrlKey || e.altKey) && !e.metaKey) {
			e.preventDefault();
			input.focus();
		}
	});

	// --- Initial setup ---
	input.focus();
	scheduleRefresh();
});
