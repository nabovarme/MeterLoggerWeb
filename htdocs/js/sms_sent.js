async function loadSMS() {
	try {
		const resp = await fetch('/api/sms_sent');
		if (!resp.ok) throw new Error(`HTTP error! status: ${resp.status}`);
		const data = await resp.json();

		const tbody = document.querySelector('#sms_table tbody');
		tbody.innerHTML = ''; // clear existing rows

		for (const row of data) {
			const tr = document.createElement('tr');
			tr.align = 'left';
			tr.valign = 'top';

			tr.innerHTML = `
				<td align="left">
					<span class="default">${row.phone}</span>
				</td>
				<td>&nbsp;</td>
				<td align="left">
					<span class="default">${row.message}</span>
				</td>
				<td>&nbsp;</td>
				<td align="left">
					<span class="default">${row.direction}</span>
				</td>
				<td>&nbsp;</td>
				<td align="left">
					<span class="default">${row.time}</span>
				</td>
			`;
			tbody.appendChild(tr);
		}
	} catch (err) {
		console.error('Failed to load sms list:', err);
	}
}

// Initial load
loadSMS();

// Refresh every 60 seconds
setInterval(loadSMS, 60 * 1000);
