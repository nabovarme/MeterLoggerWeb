let paymentDebounceTimeout = null;

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
// DEBOUNCE WRAPPER
// =========================

function reloadPaymentsDebounced() {
	clearTimeout(paymentDebounceTimeout);

	paymentDebounceTimeout = setTimeout(() => {
		loadPayments();
	}, 300);
}

// =========================
// EVENT BINDING (DIRECT)
// =========================

const input = document.getElementById('paymentsPendingSearch');

if (input) {
	// restore from URL
	const params = new URLSearchParams(window.location.search);
	input.value = params.get('q') || '';

	input.addEventListener('input', () => {
		const val = input.value;

		// update URL
		const p = new URLSearchParams(window.location.search);

		if (val) p.set('q', val);
		else p.delete('q');

		history.replaceState(null, '', `${window.location.pathname}?${p.toString()}`);

		// debounce reload
		reloadPaymentsDebounced();
	});
}

// Initial load
loadPayments();
