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

		for (const row of meters) {
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

// Initial load
loadPayments();
