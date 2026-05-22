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
			row.classList.remove('hidden'); // Uses CSS engine instead of inline layout mutation
			
			// Apply zebra striping on the fly using our visible tracker
			row.style.background = (visibleIndex % 2 === 0) ? '#FFF' : '#EEE';
			visibleIndex++;
		} else {
			row.classList.add('hidden'); // Uses CSS engine instead of inline layout mutation
		}
	});
}

document.addEventListener('DOMContentLoaded', function () {
	const input = document.getElementById('smsSentSearch');

	// Map input event directly to filter and state updates
	if (input) {
		input.focus();
		
		input.addEventListener('input', () => {
			const val = input.value.toLowerCase();
			
			// 1. Instantly filter whatever is currently on screen
			filterRows(val);
			
			// 2. Keep the URL query parameters sync'd up
			if (typeof updateURL === 'function') {
				updateURL(val);
			}
		});
	}

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

			// loadSMS now internally handles calling filterRows(query) 
			// upon completion, ensuring synchronization.

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

	scheduleRefresh();
});
