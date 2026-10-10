/* Network tree popup modal logic */

function formatUptime(seconds) {
	if (seconds < 60) {
		return seconds + ' second' + (seconds === 1 ? '' : 's');
	} else if (seconds < 3600) {
		let mins = Math.floor(seconds / 60);
		return mins + ' minute' + (mins === 1 ? '' : 's');
	} else if (seconds < 86400) {
		let hrs = Math.floor(seconds / 3600);
		return hrs + ' hour' + (hrs === 1 ? '' : 's');
	} else {
		let days = Math.floor(seconds / 86400);
		return days === 1 ? '1 day' : days + ' days';
	}
}

function buildNetworkPopupHTML(d) {
	let html = `
		<div class="default-bold" style="font-weight:bold; font-size:1.1em; margin-bottom:4px;">${d.serial} ${d.info || ''}</div>
		<div>
			<b>Valve status: </b>${d.valve_status}<br>
			<b>SSID: </b>${d.ssid}<br>
			<b>RSSI: </b><span class="chain-rssi" data-serial="${d.serial}">Loading...</span><br>
			<b>AP status: </b>${d.ap_status}<br>
			<b>Uptime: </b>${formatUptime(d.uptime)}<br>
	`;

	if (d.ping_response_time !== null && d.ping_response_time !== undefined) {
		html += `<b>Ping response time: </b>${d.ping_response_time}<br>`;
	}
	if (d.ping_average_packet_loss !== null && d.ping_average_packet_loss !== undefined) {
		html += `<b>Ping average packet loss: </b>${d.ping_average_packet_loss}<br>`;
	}
	if (d.disconnect_count !== null && d.disconnect_count !== undefined) {
		html += `<b>Disconnect count: </b>${d.disconnect_count}<br>`;
	}
	if (d.flash_id !== null && d.flash_id !== undefined) {
		html += `<b>Flash ID: </b>${d.flash_id}<br>`;
	}
	if (d.flash_size !== null && d.flash_size !== undefined) {
		html += `<b>Flash size: </b>${d.flash_size}<br>`;
	}

	html += `<b>Version: </b>${d.sw_version}<br>`;

	if (d.reset_reason !== null && d.reset_reason !== "" && d.reset_reason !== undefined) {
		html += `<b>Reset reason: </b>${d.reset_reason}<br>`;
	}

	html += `
			<!-- Flex container for triangle + label + inline status + Rescan button -->
			<div class="toggle-wifi-container" data-serial="${d.serial}" style="display:flex; align-items:center; justify-content:space-between; cursor:pointer; margin-top:6px;">
				<div style="display:flex; align-items:center;">
					<span class="toggle-wifi-triangle" style="margin-right:4px; display:inline-block; transition:transform 0.2s ease;">
						<svg viewBox="0 0 12 12" width="10" height="10"><polygon points="0,0 12,6 0,12" fill="black"/></svg>
					</span>
					<b>Visible WiFi:</b>
				</div>
				<div style="display:flex; align-items:center;">
					<span class="rescan-wifi-status" data-serial="${d.serial}" style="font-size:11px; color:#d9534f; margin-right:6px;"></span>
					<button class="btn btn-xs btn-default rescan-wifi-btn" data-serial="${d.serial}" style="padding:1px 6px; font-size:11px;">
						<i class="fa fa-refresh"></i> Rescan
					</button>
				</div>
			</div>

			<div class="wifi-table" data-serial="${d.serial}" style="display:none; max-height:200px; overflow-y:auto; margin-top:4px;">
				<i>Loading...</i>
			</div>
	`;

	if (d.valve_installed === 0 || d.comment) {
		html += `<br><i>`;
		if (d.valve_installed === 0) html += `No thermo actuator installed. `;
		if (d.comment) html += `${d.comment}`;
		html += `</i><br>`;
	}

	let linkPrefix = (d.type && d.type.match(/^water$/i)) ? '_volume' : '';
	
	html += `
			<br>
			<a href="/detail${linkPrefix}_acc.epl?serial=${d.serial}">Consumption</a> | 
			<a href="/detail${linkPrefix}.epl?serial=${d.serial}">Details</a><br>
		</div>
	`;

	return html;
}

function bindNetworkPopupEvents(container) {
	if (!container) return;

	const toggleContainer = container.querySelector('.toggle-wifi-container');
	if (!toggleContainer) return;

	const serial = toggleContainer.dataset.serial;
	const tableDiv = container.querySelector(`.wifi-table[data-serial="${serial}"]`);
	const triangle = container.querySelector('.toggle-wifi-triangle');
	const rescanBtn = container.querySelector('.rescan-wifi-btn[data-serial="' + serial + '"]');

	// Fetch weakest RSSI
	const rssiSpan = container.querySelector('.chain-rssi[data-serial="' + serial + '"]');
	if (rssiSpan && !rssiSpan.dataset.loaded) {
		fetch('/api/wifi_mesh_rssi/' + encodeURIComponent(serial))
			.then(res => res.json())
			.then(data => {
				if (!data || typeof data.weakest_rssi === 'undefined') {
					rssiSpan.innerHTML = 'N/A';
					return;
				}

				const hops = data.hop_count || (data.chain ? data.chain.length : 0);
				rssiSpan.innerHTML =
					`<span>${data.weakest_rssi} dBm` +
						(hops ? ` (${hops} hop${hops > 1 ? 's' : ''})` : '') +
					`</span>`;

				rssiSpan.dataset.loaded = "1";
			})
			.catch(() => {
				rssiSpan.innerHTML = 'Error';
			});
	}

	function loadWifiTable(forceRefresh = false) {
		if (forceRefresh) {
			tableDiv.innerHTML = '<i>Refreshing scan data...</i>';
			delete container.dataset.loaded;
		} else if (container.dataset.loaded === "1") {
			return;
		}

		tableDiv.innerHTML = '<i>Loading...</i>';

		fetch('/api/wifi_scan/' + encodeURIComponent(serial))
			.then(res => {
				if (!res.ok) throw new Error('HTTP ' + res.status);
				return res.json();
			})
			.then(data => {
				if (!data || !data.length) {
					tableDiv.innerHTML = '<i>No scan data</i>';
					container.dataset.loaded = "1";
					return;
				}

				tableDiv.innerHTML = `
					<table class="table table-condensed table-striped popup-table" style="font-size:14px; margin:0; width:100%;">
						<thead><tr><th>SSID</th><th>RSSI</th><th>Hop</th><th>Ch</th><th>Auth</th></tr></thead>
						<tbody>${data.map(ap => {
							const color = ap.rssi > -65 ? '#5cb85c' : ap.rssi > -75 ? '#f0ad4e' : '#d9534f';
							const encodedSSID = encodeURIComponent(ap.ssid || '');
							
							let displaySSID = ap.ssid || '(hidden)';
							if (ap.info) {
								displaySSID += ` (${ap.info})`;
							}
							
							const activeBadge = ap.connected ? ' <i class="fa fa-check" style="color:green;" title="Currently Connected"></i>' : '';
							
							return `<tr>
								<td><a href="/update_wifi.html?serial=${encodeURIComponent(serial)}&ssid=${encodedSSID}">${displaySSID}</a>${activeBadge}</td>
								<td style="color:${color}">${ap.rssi} dBm</td>
								<td>${ap.hop || ''}</td>
								<td>${ap.channel}</td>
								<td>${ap.auth_mode}</td>
							</tr>`;
						}).join('')}</tbody>
					</table>`;

				container.dataset.loaded = "1";
			})
			.catch(() => {
				delete container.dataset.loaded;
				tableDiv.innerHTML = '<span style="color:red">Error loading WiFi (click Visible WiFi to retry)</span>';
			});
	}

	loadWifiTable();

	toggleContainer.addEventListener('click', (evt) => {
		if (evt.target.closest('.rescan-wifi-btn')) return;

		if (tableDiv.style.display === 'none') {
			tableDiv.style.display = 'block';
			if (triangle) triangle.style.transform = 'rotate(90deg)';
			loadWifiTable();
		} else {
			tableDiv.style.display = 'none';
			if (triangle) triangle.style.transform = 'rotate(0deg)';
		}
	});

	if (rescanBtn && !rescanBtn.dataset.bound) {
		rescanBtn.dataset.bound = "1";
		rescanBtn.addEventListener('click', (evt) => {
			evt.stopPropagation();

			const statusSpan = container.querySelector('.rescan-wifi-status[data-serial="' + serial + '"]');
			if (statusSpan) statusSpan.textContent = '';

			rescanBtn.disabled = true;
			rescanBtn.innerHTML = '<i class="fa fa-spinner fa-spin"></i> Scanning...';

			fetch('/api/wifi_scan_request/' + encodeURIComponent(serial), { method: 'POST' })
				.then(res => res.json().then(data => ({ ok: res.ok, status: res.status, data }))
					.catch(() => ({ ok: false, data: { error: 'Invalid response' } })))
				.then(({ ok, status, data }) => {
					if (data.status === 'ok') {
						tableDiv.style.display = 'block';
						if (triangle) triangle.style.transform = 'rotate(90deg)';
						loadWifiTable(true);
					} else if (data.status === 'queued') {
						if (statusSpan) statusSpan.textContent = 'Queued (awaiting meter...)';
						tableDiv.style.display = 'block';
						if (triangle) triangle.style.transform = 'rotate(90deg)';
						
						setTimeout(() => {
							loadWifiTable(true);
							if (statusSpan) statusSpan.textContent = '';
						}, 10000);
					} else {
						if (statusSpan) statusSpan.textContent = data.error || 'Server error';
					}
				})
				.catch(err => {
					console.error(err);
					if (statusSpan) statusSpan.textContent = 'Network error';
				})
				.finally(() => {
					rescanBtn.disabled = false;
					rescanBtn.innerHTML = '<i class="fa fa-refresh"></i> Rescan';
				});
		});
	}
}

function openNetworkPopup(ssid, serial) {
	let modal = document.getElementById('networkPopupModal');
	if (!modal) {
		const modalHTML = `
			<div id="networkPopupModal" style="display:none; position:fixed; top:0; left:0; width:100%; height:100%; background:rgba(0,0,0,0.5); z-index:9999; justify-content:center; align-items:center;">
				<div style="background:#fff; padding:20px; border-radius:8px; max-width:480px; width:90%; max-height:80vh; overflow-y:auto; position:relative; box-shadow:0 4px 10px rgba(0,0,0,0.3); font-family:sans-serif;">
					<span id="closeNetworkPopupModal" style="position:absolute; top:8px; right:14px; font-size:24px; cursor:pointer; font-weight:bold;">&times;</span>
					<div id="networkPopupContent">Loading...</div>
				</div>
			</div>
		`;
		document.body.insertAdjacentHTML('beforeend', modalHTML);

		modal = document.getElementById('networkPopupModal');
		document.getElementById('closeNetworkPopupModal').addEventListener('click', closeNetworkPopup);
		modal.addEventListener('click', (e) => {
			if (e.target.id === 'networkPopupModal') closeNetworkPopup();
		});
	}

	const contentDiv = document.getElementById('networkPopupContent');
	modal.style.display = 'flex';
	contentDiv.innerHTML = '<i>Loading details...</i>';

	fetch('/api/meters/detail?serial=' + encodeURIComponent(serial))
		.then(res => {
			if (!res.ok) throw new Error('HTTP ' + res.status);
			return res.json();
		})
		.then(meterData => {
			const d = Array.isArray(meterData) ? meterData[0] : meterData;
			if (!d) throw new Error('No meter found for serial ' + serial);

			contentDiv.innerHTML = buildNetworkPopupHTML(d);
			bindNetworkPopupEvents(contentDiv);
		})
		.catch(err => {
			contentDiv.innerHTML = `<p style="color:red;">Error loading details for meter ${serial}: ${err.message}</p>`;
		});
}

function closeNetworkPopup() {
	const modal = document.getElementById('networkPopupModal');
	if (modal) modal.style.display = 'none';
}

window.openNetworkPopup = openNetworkPopup;
window.closeNetworkPopup = closeNetworkPopup;
