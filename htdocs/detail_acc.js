// -------------------------
// Energy Detail Dashboard (ECharts Version)
// -------------------------

// Colors
const colorSets = ['#999999', '#2c7be5'];

// Graph instance
let chart;

// Data and API URLs
const dataUrlCoarse = `/api/data_acc/${meter_serial}/coarse`;
const dataUrlFine = `/api/data_acc/${meter_serial}/fine`;
const accountUrl = `/api/account/${meter_serial}`;

// Cached account data
let accountData = null;

// ----------------------
// Helper functions
// ----------------------

// Convert CSV timestamps from seconds → milliseconds
function convertCsvSecondsToMs(csv) {
	const lines = csv.trim().split("\n");
	const header = lines[0];
	const converted = lines.slice(1).map(line => {
		const parts = line.split(",");
		parts[0] = (parseInt(parts[0], 10) * 1000).toString();
		return parts.join(",");
	});
	return [header, ...converted].join("\n");
}

// Merge two CSV strings by timestamp
function mergeCsv(csv1, csv2) {
	const lines1 = csv1.trim().split("\n");
	const lines2 = csv2.trim().split("\n");

	const header = lines1[0];
	const allLines = lines1.slice(1).concat(lines2.slice(1));

	const uniqueRows = new Map();
	for (const line of allLines) {
		const ts = line.split(",")[0];
		uniqueRows.set(ts, line);
	}

	const sortedRows = Array.from(uniqueRows.values()).sort((a, b) =>
		parseInt(a.split(",")[0], 10) - parseInt(b.split(",")[0], 10)
	);

	return [header].concat(sortedRows).join("\n");
}

// Parse CSV → array of {time, energy, remaining}
function parseCsv(csv) {
	const lines = csv.trim().split("\n");
	const header = lines[0].split(",");
	const data = lines.slice(1).map(line => {
		const parts = line.split(",");
		return {
			time: parseInt(parts[0], 10),
			energy: parseFloat(parts[1]),
			remaining: parts[2] !== '' ? parseFloat(parts[2]) : null
		};
	});
	return data;
}

// Format time nicely
function formatDate(ms) {
	const d = new Date(ms);
	return `${d.getDate().toString().padStart(2,'0')}.${(d.getMonth()+1).toString().padStart(2,'0')}.${d.getFullYear()} ${d.getHours().toString().padStart(2,'0')}:${d.getMinutes().toString().padStart(2,'0')}`;
}

// ----------------------
// UI update functions
// ----------------------
function updateConsumptionFromRange(start, end, data) {
	const inRange = data.filter(d => d.time >= start && d.time <= end);
	if (!inRange.length) return;

	const minY = inRange[0].energy;
	const maxY = inRange[inRange.length-1].energy;

	const consumption = maxY - minY;
	const avg = consumption / ((end - start) / (1000*3600));

	document.getElementById('consumption_in_range').innerHTML =
		`<span class="default-bold">Consumption for selected period </span>` +
		`<span class="default">${consumption.toFixed(0)} kWh, at ${avg.toFixed(2)} kW/h</span>`;

	filterPaymentsBySelectedGraphRange(start, end);
}

function updateLastReadingStats() {
	document.getElementById("last_energy").innerHTML =
		parseFloat(accountData.last_energy).toFixed(0) + " kWh<br>" +
		parseFloat(accountData.last_volume).toFixed(0) + " m<sup>3</sup><br>" +
		parseFloat(accountData.last_hours).toFixed(0) + " hours<br>";
}

function updateRemainingKwhInfo() {
	if (accountData && accountData.kwh_remaining != null) {
		const kwhRemainingInt = Math.round(accountData.kwh_remaining);
		document.getElementById("kwh_remaining").innerHTML =
			`${kwhRemainingInt} kWh remaining, ${accountData.time_remaining_hours_string} at ${parseFloat(accountData.avg_energy_last_day).toFixed(2)} kW/h`;
	}
}

function renderPaymentRowsFromAccountData(payments) {
	const container = document.getElementById("payments_table");
	container.innerHTML = '';

	if (!payments.length) {
		container.innerHTML = '<div class="payment-row empty">No payments data available</div>';
		return;
	}

	const header = document.createElement('div');
	header.className = 'payment-row payment-header';
	header.innerHTML = `<div>Date</div><div>Info</div><div>Amount</div><div>Price</div>`;
	container.appendChild(header);

	payments.forEach(d => {
		const row = document.createElement('div');
		row.className = 'payment-row';
		row.id = `payment-${d.id}`;
		row.setAttribute('data-payment-time', d.payment_time);

		const kWh = (d.type === 'payment' && d.price) ? Math.round(d.amount / d.price) + ' kWh' : '';
		const amountStr = parseFloat(d.amount || 0).toFixed(2) + ' kr';
		const priceStr = (d.type === 'payment' && d.price) ? parseFloat(d.price || 0).toFixed(2) + ' kr/kWh' : '';

		const dateObj = new Date(d.payment_time*1000);
		const dateStr = `${dateObj.getDate()}.${dateObj.getMonth()+1}.${dateObj.getFullYear()} ${dateObj.getHours().toString().padStart(2,'0')}:${dateObj.getMinutes().toString().padStart(2,'0')}`;

		row.innerHTML = `<div>${dateStr}</div><div>${kWh} ${d.info || ''}</div><div>${amountStr}</div><div>${priceStr}</div>`;
		container.appendChild(row);
	});
}

function filterPaymentsBySelectedGraphRange(start, end) {
	const rows = document.querySelectorAll('#payments_table .payment-row:not(.payment-header):not(.empty)');
	rows.forEach(row => {
		const ts = parseInt(row.getAttribute('data-payment-time'))*1000;
		row.style.display = (ts >= start && ts <= end) ? '' : 'none';
	});
}

// ----------------------
// Fetch & render account info
// ----------------------
async function fetchAndRenderAccountInfo(data) {
	try {
		const res = await fetch(accountUrl);
		const acct = await res.json();
		accountData = acct;

		updateRemainingKwhInfo();
		updateLastReadingStats();

		renderPaymentRowsFromAccountData(acct.account);
		return acct;
	} catch (err) {
		console.warn('Failed to fetch account data', err);
	}
}

// ----------------------
// Main fetch & update function
// ----------------------
async function fetchAndUpdateGraph() {
	const container = document.getElementById("div_dygraph");
	const spinner = document.getElementById("graph_spinner");
	if (spinner) spinner.style.display = "block";

	try {
		// --- Coarse CSV ---
		let coarseCsv = await (await fetch(dataUrlCoarse)).text();
		coarseCsv = convertCsvSecondsToMs(coarseCsv);

		// --- Parse Coarse ---
		let data = parseCsv(coarseCsv);

		// --- Fetch & render account ---
		await fetchAndRenderAccountInfo(data);

		// --- Fine CSV ---
		let fineCsv = await (await fetch(dataUrlFine)).text();
		fineCsv = convertCsvSecondsToMs(fineCsv);

		// --- Merge CSVs ---
		const mergedCsv = mergeCsv(coarseCsv, fineCsv);
		data = parseCsv(mergedCsv);

		// --- Build ECharts option ---
		const option = {
			tooltip: {
				trigger: 'axis',
				formatter: params => {
					const p = params[0];
					const date = formatDate(p.data[0]);
					const energy = p.data[1];
					const remaining = p.data[2] != null ? p.data[2] : 'N/A';
					return `Time: ${date}<br>Energy: ${energy} kWh<br>Remaining: ${remaining} kWh`;
				}
			},
			legend: { data: ['Energy', 'Remaining'] },
			xAxis: { type: 'time' },
			yAxis: { type: 'value', name: 'kWh' },
			dataZoom: [
				{ type: 'slider', xAxisIndex: 0 },
				{ type: 'inside', xAxisIndex: 0 }
			],
			series: [
				{
					name: 'Energy',
					type: 'line',
					showSymbol: false,
					data: data.map(d => [d.time, d.energy, d.remaining])
				},
				{
					name: 'Remaining',
					type: 'line',
					step: 'start',
					showSymbol: false,
					data: data.map(d => [d.time, d.remaining])
				}
			]
		};

		// --- Init or update chart ---
		if (!chart) {
			chart = echarts.init(container);
			chart.setOption(option);

			// Zoom/brush listener to update consumption and table
			chart.on('dataZoom', params => {
				const axis = chart.getModel().getComponent('xAxis', 0);
				const start = axis.scale.getExtent()[0];
				const end = axis.scale.getExtent()[1];
				updateConsumptionFromRange(start, end, data);
			});
		} else {
			chart.setOption(option, { notMerge: true });
		}

	} catch (err) {
		console.error('Error updating graph', err);
	} finally {
		if (spinner) spinner.style.display = "none";
	}
}

// Initial load
fetchAndUpdateGraph();
// Refresh every 60s
setInterval(fetchAndUpdateGraph, 60000);
