async function loadWifi() {
	try {
		const resp = await fetch('/api/wifi_pending');
		if (!resp.ok) throw new Error(`HTTP error! status: ${resp.status}`);
		const data = await resp.json();

		const tbody = document.querySelector('#wifi_table tbody');
		tbody.innerHTML = ''; // clear existing rows

		for (const row of data) {
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
	} catch (err) {
		console.error('Failed to load wifi:', err);
	}
}

// Initial load
loadWifi();
