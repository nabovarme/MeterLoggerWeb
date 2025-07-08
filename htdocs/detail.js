var current_hash_string = window.location.hash;
var current_range = current_hash_string.match(/#(.+?)\-(.+?)(?:;\d+$)?$/);
var current_url = window.location.href.replace(/#.*$/, "");

var range = current_range
	? [parseFloat(current_range[1]), parseFloat(current_range[2])]
	: [Date.now() - 86400000, Date.now()];

var data_series_enabled = (current_hash_string.match(/;(\d+)$/) || [])[1] || 31;
var reload_time = Date.now();

var colorSets = [['#a9000c', '#011091', '#d7c8dd', '#ad6933', '#00982f'], null];
var g;

var dataUrlCoarse = 'data/' + meter_serial + '/coarse';
var dataUrlFine = 'data/' + meter_serial + '/fine';

// Fetch coarse data and initialize Dygraph
fetch(dataUrlCoarse)
	.then(r => r.text())
	.then(coarseCsv => {
		g = new Dygraph(
			document.getElementById("div_nabovarme"),
			coarseCsv,
			{
				delimiter: ',',
				colors: colorSets[0],
				strokeWidth: 1.5,
				animatedZooms: true,
				showLabelsOnHighlight: true,
				labelsDivStyles: {
					'font-family': 'Verdana, Geneva, sans-serif',
					'text-align': 'left',
					'background': 'none'
				},
				labelsSeparateLines: true,
				labelsDivWidth: 700,
				showRangeSelector: true,
				interactionModel: Dygraph.defaultInteractionModel,
				dateWindow: range,
				axes: {
					x: {
						valueFormatter: x => formatDate(new Date(x))
					}
				},
				highlightSeriesOpts: {
					pointSize: 6,
					highlightCircleSize: 6,
					strokeWidth: 2,
					strokeBorderWidth: 1,
				},
				unhighlightCallback: updateUrlFromGraph,
				zoomCallback: updateUrlFromGraph,
				clickCallback: updateUrlFromGraph
			}
		);

		g.ready(() => {
			for (let i = 0; i < 5; i++) {
				const checkbox = document.getElementById(i);
				checkbox.checked = ((data_series_enabled >> i) & 1) !== 0;
				g.setVisibility(i, checkbox.checked);
			}

			// Load fine data and merge
			fetch(dataUrlFine)
				.then(r => r.text())
				.then(fineCsv => {
					const merged = mergeCsv(coarseCsv, fineCsv);
					g.updateOptions({ file: merged });
				});

			console.log('range:', g.xAxisRange());
		});
	});

// Refresh every minute
setInterval(() => {
	Promise.all([
		fetch(dataUrlCoarse).then(r => r.text()),
		fetch(dataUrlFine).then(r => r.text())
	]).then(([coarseCsv, fineCsv]) => {
		const merged = mergeCsv(coarseCsv, fineCsv);

		const reload_time_diff = Date.now() - reload_time;
		reload_time = Date.now();
		range[0] += reload_time_diff;
		range[1] += reload_time_diff;

		g.updateOptions({ file: merged, dateWindow: range });
		updateLastReadingStats();

		window.history.replaceState("", "", `${current_url}#${range[0]}-${range[1]};${data_series_enabled}`);
	});
}, 60000);

// Helpers
function mergeCsv(csv1, csv2) {
	const lines1 = csv1.trim().split("\n");
	const lines2 = csv2.trim().split("\n");
	const header = lines1[0];
	const allLines = lines1.slice(1).concat(lines2.slice(1));

	const unique = new Map();
	allLines.forEach(line => {
		const time = line.split(",")[0];
		unique.set(time, line);
	});

	const sorted = Array.from(unique.values()).sort((a, b) =>
		new Date(a.split(",")[0]) - new Date(b.split(",")[0])
	);

	return [header, ...sorted].join("\n");
}

function formatDate(d) {
	const pad = n => n < 10 ? "0" + n : n;
	const date = `${d.getDate()}.${d.getMonth() + 1}.${d.getFullYear()}`;
	const time = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
	return d.getTime() < Date.now() - 86400000 ? `Time: ${date} ${time}` : `Time: ${time}`;
}

function updateUrlFromGraph() {
	range = g.xAxisRange();
	if (isNaN(range[0]) || isNaN(range[1]) || range[0] >= range[1]) {
		range = [Date.now() - 86400000, Date.now()];
		g.updateOptions({ dateWindow: range });
	}
	window.history.replaceState("", "", `${current_url}#${range[0]}-${range[1]};${data_series_enabled}`);
}

function change(el) {
	const index = parseInt(el.id);
	g.setVisibility(index, el.checked);
	data_series_enabled = el.checked
		? data_series_enabled | (1 << index)
		: data_series_enabled & ~(1 << index);

	window.history.replaceState("", "", `${current_url}#${range[0]}-${range[1]};${data_series_enabled}`);
}

function updateLastReadingStats() {
	fetch('last_energy.epl?serial=' + meter_serial)
		.then(r => r.text())
		.then(text => {
			document.getElementById("last_energy").innerHTML = text;
		});
}
