// status_dashboard.js
document.addEventListener("DOMContentLoaded", async () => {
	// Exact container namespace keys (underscores)
	const expectedServices = [
		'web',
		'meter_grapher',
		'mysql_mqtt_command_queue_receive',
		'mysql_mqtt_command_queue_send',
		'smsd',
		'smsd_watchdog',
		'meter_notify',
		'meter_alarm',
		'meter_cron',
		'openresty',
		'utils',
		'prometheus_exporter',
		'firmware_builder',
		'firmware_watcher'
	];

	const tbody = document.getElementById("manifest-body");
	const errorDisplay = document.getElementById("error-display");

	// Formats standard Unix timestamps (seconds) into clean uptime intervals
	function calculateUptime(createdUnixSeconds) {
		if (!createdUnixSeconds) return '---';
	
		const start = new Date(createdUnixSeconds * 1000);
		const now = new Date();
		const diffMs = now - start;
	
		if (isNaN(diffMs) || diffMs < 0) return 'Running';
	
		const diffHours = diffMs / (1000 * 60 * 60);
		if (diffHours < 24) {
			return `${diffHours.toFixed(1)} hrs`;
		}
		return `${(diffHours / 24).toFixed(1)} days`;
	}

	try {
		// Query modernized native Apache proxy endpoint
		const response = await fetch('/api/status');
		if (!response.ok) throw new Error(`Application Proxy Fault: ${response.status}`);
	
		const data = await response.json();
		let activeContainers = {};
		let htmlRows = "";

		// Parse properties using verified Docker Engine naming conventions
		data.forEach(container => {
			const labels = container.Labels || {};
			const serviceName = labels['com.docker.compose.service'];
		
			if (serviceName && expectedServices.includes(serviceName)) {
				const isRunning = container.State === 'running';
			
				activeContainers[serviceName] = {
					running: isRunning,
					version: labels['app.git.commit'] || 'unknown',
					uptime: isRunning ? container.Created : null
				};
			}
		});

		// Walk static sequence index array to generate output markup rows
		expectedServices.forEach(service => {
			const node = activeContainers[service];
		
			if (node && node.running) {
				const printHash = node.version !== 'unknown' ? node.version.substring(0, 12) : 'No Build Hash';
			
				htmlRows += `
					<tr>
						<td><strong>${service}</strong></td>
						<td><span class="status-badge status-online">RUNNING</span></td>
						<td class="metric-text">${calculateUptime(node.uptime)}</td>
						<td><span class="git-hash">${printHash}</span></td>
					</tr>
				`;
			} else {
				htmlRows += `
					<tr>
						<td><strong style="color: #a0a0a0;">${service}</strong></td>
						<td><span class="status-badge status-offline">OFFLINE</span></td>
						<td class="metric-text" style="color: #ccc;">---</td>
						<td><span class="git-hash" style="color: #bbb; background: #fafafa; border-color: #eee;">------</span></td>
					</tr>
				`;
			}
		});

		tbody.innerHTML = htmlRows;

	} catch (err) {
		console.error("Failed processing cluster mapping diagnostics:", err);
		const loadingRow = document.getElementById("loading-row");
		if (loadingRow) {
			loadingRow.innerText = "Unable to process cluster telemetry architecture.";
		}
		if (errorDisplay) {
			errorDisplay.innerText = `Dashboard Connection Error: Verification error parsing state objects from the /api/status proxy stream.`;
			errorDisplay.style.display = "block";
		}
	}
});
