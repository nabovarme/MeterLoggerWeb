let paymentDebounceTimeout = null;

const SCROLL_KEY = 'payments_pending_scroll';

document.addEventListener('DOMContentLoaded', () => {
	const input = document.getElementById('paymentsPendingSearch');

	// =========================
	// SCROLL (global manager)
	// =========================
	bindScrollPersistence(SCROLL_KEY);
	enableAutoRestore(SCROLL_KEY);

	// =========================
	// LOAD DATA
	// =========================
	async function loadPayments() {
		try {
			const resp = await fetch('/api/payments_pending');
			if (!resp.ok) throw new Error(`HTTP error! status: ${resp.status}`);
			const data = await resp.json();

			// Extract meters and the close_warning_threshold_hours
			const meters = data.meters || [];
			const warningThreshold = data.close_warning_threshold_hours || 3 * 24; // fallback 3 days

			const tbody = document.querySelector('#payments_table tbody');
			tbody.innerHTML = ''; // clear existing rows

			// =========================
			// URL STATE (READ)
			// =========================
			const params = new URLSearchParams(window.location.search);
			const search = (params.get('q') || '').toLowerCase();

			for (const row of meters) {

				if (search) {
					const text = `${row.serial || ''} ${row.info || ''}`.toLowerCase();
					if (!text.includes(search)) continue;
				}

				const tr = document.createElement('tr');
				tr.align = 'left';
				tr.valign = 'top';

				// --- Assign classes based on time_remaining_hours ---
				if (row.time_remaining_hours !== null && row.time_remaining_hours !== undefined) {
					if (row.time_remaining_hours <= 0) {
						tr.classList.add('time-zero'); // red
					} else if (row.time_remaining_hours <= warningThreshold) {
						tr.classList.add('time-low'); // yellow
					}
				}

				tr.innerHTML = `
					<td align="left">
						<a href="detail_acc.epl?serial=${encodeURIComponent(row.serial || '')}">
							<span class="default">${row.serial}</span>
						</a>
					</td>
					<td>&nbsp;</td>
					<td align="left"><span class="default">${row.info}</span></td>
					<td>&nbsp;</td>
					<td align="left"><span class="default">${row.open_until.toFixed(2)}</span></td>
					<td>&nbsp;</td>
					<td align="left"><span class="default">${row.time}</span></td>
				`;

				tbody.appendChild(tr);
			}

		} catch (err) {
			console.error('Failed to load payments:', err);
		}
	}

	// =========================
	// INLINE DEBOUNCE (NO HELPER FILE)
	// =========================
	function debounce(fn, delay = 300) {
		let timeoutId;

		return (...args) => {
			clearTimeout(timeoutId);
			timeoutId = setTimeout(() => fn(...args), delay);
		};
	}

	const reloadPaymentsDebounced = debounce(loadPayments, 300);

	// =========================
	// SEARCH INPUT
	// =========================
	if (input) {

		// restore from URL
		input.value = getQueryParam('q');

		input.addEventListener('input', () => {
			const val = input.value;

			setQueryParam('q', val);

			reloadPaymentsDebounced();
		});
	}

	// =========================
	// INIT
	// =========================
	loadPayments();
});
