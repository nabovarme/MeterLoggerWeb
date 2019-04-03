var current_hash_string = window.location.hash;
var current_range = current_hash_string.match(/#(.+?)\-(.+?)(?:;\d+$)?$/);

// remove url after #
var current_url = window.location.href;
var current_url = current_url.replace(/#.*$/, "");

var range = [];
if (current_range) {
	range.push(parseFloat(current_range[1]));
	range.push(parseFloat(current_range[2]));
}
else {
	// set default
	range = [ (Date.now() - 86400000), Date.now() ];
}

var current_data_series_enabled = current_hash_string.match(/;(\d+)$/);
var data_series_enabled = 0;
if (current_data_series_enabled) {
	data_series_enabled = current_data_series_enabled[1];
}
else {
	// set default
	data_series_enabled = 31;	// 0, 1, 3, 4, 5
}

window.reload_time = Date.now();
var colorSets = [
	['#a9000c', '#011091', '#d7c8dd', '#ad6933', '#00982f'],
	null
];
var g;
var drawGraph = function(data) {
	window.g = new Dygraph(
		document.getElementById("div_nabovarme"), data, {
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
			axes: {
				x: {
					valueFormatter: function(x) {
						return formatDate(new Date(x));
					}
				}
			},
			highlightSeriesOpts: {
				pointSize: 6,
				highlightCircleSize: 6,
				strokeWidth: 2,
				strokeBorderWidth: 1,
			},
			showRangeSelector: true,
			interactionModel: Dygraph.defaultInteractionModel,
			dateWindow: window.range,
			unhighlightCallback: function(e) {
				window.range = this.xAxisRange();
				console.log('unhighlightCallback: ' + window.range);
				if (isNaN(window.range[0]) || isNaN(window.range[1]) || (window.range[0] >= window.range[1])) {
					console.log('range out of bounds: ' + window.range);
					window.range = [ (Date.now() - 86400000), Date.now() ];
					this.updateOptions( { dateWindow: window.range } );								
				}
				window.history.replaceState("", "", current_url + "#" + window.range[0] + "-" + window.range[1] + ';' + data_series_enabled);
			},
			zoomCallback: function(minDate, maxDate, yRanges) {
				window.range = this.xAxisRange();
				console.log('zoomCallback: ' + window.range);
				if (isNaN(window.range[0]) || isNaN(window.range[1]) || (window.range[0] >= window.range[1])) {
					console.log('range out of bounds: ' + window.range);
					window.range = [ (Date.now() - 86400000), Date.now() ];
					this.updateOptions( { dateWindow: window.range } );								
				}
				window.history.replaceState("", "", current_url + "#" + window.range[0] + "-" + window.range[1] + ';' + data_series_enabled);
			},
			clickCallback: function(e, x, points) {
				window.range = this.xAxisRange();
				console.log('clickCallback: ' + window.range);
				if (isNaN(window.range[0]) || isNaN(window.range[1]) || (window.range[0] >= window.range[1])) {
					console.log('range out of bounds: ' + window.range);
					window.range = [ (Date.now() - 86400000), Date.now() ];
					this.updateOptions( { dateWindow: window.range } );								
				}
				window.history.replaceState("", "", current_url + "#" + window.range[0] + "-" + window.range[1] + ';' + data_series_enabled);
			}
		}
	);
	window.g.ready(function () {
		// get state from url
		document.getElementById("0").checked = ((data_series_enabled >> 0) & 1) ? true : false;
		document.getElementById("1").checked = ((data_series_enabled >> 1) & 1) ? true : false;
		document.getElementById("2").checked = ((data_series_enabled >> 2) & 1) ? true : false;
		document.getElementById("3").checked = ((data_series_enabled >> 3) & 1) ? true : false;
		document.getElementById("4").checked = ((data_series_enabled >> 4) & 1) ? true : false;

		// update dygraphs to reflect state
		this.setVisibility(0, document.getElementById("0").checked); 
		this.setVisibility(1, document.getElementById("1").checked); 
		this.setVisibility(2, document.getElementById("2").checked); 
		this.setVisibility(3, document.getElementById("3").checked); 
		this.setVisibility(4, document.getElementById("4").checked); 
		console.log('range: ' + this.xAxisRange());
	});
}

var data_url_new = 'data/' + window.meter_serial + '/new_range';
var data_url_old = 'data/' + window.meter_serial + '/old_range';
var data_new = '';
var data_old = '';

var xhttp_old = new XMLHttpRequest();
xhttp_old.onreadystatechange = function() {
	if (xhttp_old.readyState == 4 && xhttp_old.status == 200) {
		// stop spinner
		spinner.stop();
		
		window.data_old = xhttp_old.responseText;
		drawGraph(window.data_old + window.data_new);
	}
}

var xhttp_new = new XMLHttpRequest();
xhttp_new.onreadystatechange = function() {
	if (xhttp_new.readyState == 4 && xhttp_new.status == 200) {
		window.data_new = xhttp_new.responseText;
		xhttp_old.open('GET', window.data_url_old, true);
		xhttp_old.send();
	}
}
xhttp_new.open('GET', data_url_new, true);
xhttp_new.send();

setInterval(function() {
	// update data
	console.log("update data and pan right");
	var xhttp_old = new XMLHttpRequest();
	xhttp_old.onreadystatechange = function() {
		if (xhttp_old.readyState == 4 && xhttp_old.status == 200) {
			window.data_old = xhttp_old.responseText;
			drawGraph(window.data_old + window.data_new);

			var reload_time_diff = Date.now() - window.reload_time;
			window.reload_time = Date.now();
			window.range[0] += reload_time_diff;
			window.range[1] += reload_time_diff;
			window.g.updateOptions( { file: data_old + data_new, dateWindow: window.range } );

			window.history.replaceState("", "", current_url + "#" + window.range[0] + "-" + window.range[1] + ';' + data_series_enabled);
		}
	}
	// ...and pan right
	var xhttp_new = new XMLHttpRequest();
	xhttp_new.onreadystatechange = function() {
		if (xhttp_new.readyState == 4 && xhttp_new.status == 200) {
			window.data_new = xhttp_new.responseText;
			xhttp_old.open('GET', window.data_url_old, true);
			xhttp_old.send();
		}
	}
	xhttp_new.open('GET', window.data_url_new, true);
	xhttp_new.send();
	
	update_last_energy();
}, 60000);

function formatDate(d) {
	var year = d.getFullYear(),
	month = d.getMonth() + 1,
	date = d.getDate(),
	hours = d.getHours(),
	minutes = d.getMinutes(),
	seconds = d.getSeconds();
	
	var now = new Date();
	if (d.getTime() < now.getTime() - (1000 * 86400)) {
		return 'Time: ' + date + '.' + month + '.' + year + ' ' + 
			hours + ':' + (minutes < 10 ? '0' : '') + minutes + ':' + (seconds < 10 ? '0' : '') + seconds;
	}
	else {
		return 'Time: ' + hours + ':' + (minutes < 10 ? '0' : '') + minutes + ':' + (seconds < 10 ? '0' : '') + seconds;
	}
}

function change(el) {
	window.g.setVisibility(parseInt(el.id), el.checked);
	
	if (el.checked) {
		window.data_series_enabled += 1 << parseInt(el.id);
	}
	else {
		window.data_series_enabled -= 1 << parseInt(el.id);
	}
	console.log(window.data_series_enabled);
	window.history.replaceState("", "", current_url + "#" + window.range[0] + "-" + window.range[1] + ';' + window.data_series_enabled);
}

function update_last_energy() {
	var xhttp = new XMLHttpRequest();
	xhttp.onreadystatechange = function() {
		if (xhttp.readyState == 4 && xhttp.status == 200) {
			document.getElementById("last_energy").innerHTML = xhttp.responseText;
		}
	};
	xhttp.open("GET", "last_energy.epl?serial=" + window.meter_serial, true);
	xhttp.send();
}
