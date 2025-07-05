async function loadPayments() {
	try {
		const resp = await fetch('/api/payments_pending');
		if (!resp.ok) throw new Error(`HTTP error! status: ${resp.status}`);
		const data = await resp.json();

		const tbody = document.querySelector('#payments-table tbody');
		tbody.innerHTML = ''; // clear existing rows

		for (const row of data) {
			const tr = document.createElement('tr');
			tr.align = 'left';
			tr.valign = 'top';

			tr.innerHTML = `
				<td align="left"><span class="default">${row.serial}</span></td>
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

// Refresh every 60 seconds
setInterval(loadPayments, 60 * 1000);
