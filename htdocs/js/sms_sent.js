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

			// --- Phone link ---
			const phoneLink = `<a href="#" class="phone-link" data-phone="${row.phone}">${row.phone}</a>`;

			// --- Convert serials in message to links ---
			let messageHTML = row.message;

			// Pattern: "text: ... (<serial>)"
			const regex = /^(Open notice|Close notice|Close warning):.*\((\d+)\)$/;
			const match = messageHTML.match(regex);
			if (match) {
				const serial = match[2];
				const serialLink = `<a href="/detail_acc.epl?serial=${serial}">${serial}</a>`;
				// Replace "(1234567)" with clickable link
				messageHTML = messageHTML.replace(`(${serial})`, `(${serialLink})`);
			}

			tr.innerHTML = `
				<td align="left">${phoneLink}</td>
				<td>&nbsp;</td>
				<td align="left"><span class="default">${messageHTML}</span></td>
				<td>&nbsp;</td>
				<td align="left"><span class="default">${row.direction}</span></td>
				<td>&nbsp;</td>
				<td align="left"><span class="default">${row.time}</span></td>
			`;

			tbody.appendChild(tr);
		}

		// Add click handlers for phone links
		document.querySelectorAll('.phone-link').forEach(link => {
			link.addEventListener('click', function (e) {
				e.preventDefault();
				const last8 = this.dataset.phone.slice(-8);
				const input = document.getElementById('smsSentSearch');
				input.value = last8;
				filterRows(last8.toLowerCase());
				input.focus();
			});
		});

		// Update row colors
		const rows = tbody.querySelectorAll('tr');
		rows.forEach((row, index) => {
			row.style.background = (index % 2 === 0) ? '#FFF' : '#EEE';
		});

	} catch (err) {
		console.error('Failed to load SMS list:', err);
	}
}


// --- Initial load ---
loadSMS();
