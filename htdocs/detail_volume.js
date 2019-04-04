var current_range_string = window.location.hash;
var current_range = current_range_string.match(/#(.+?)\-(.+?)$/);

// remove url after #
var current_url = window.location.href;
current_url = current_url.replace(/#.*$/, "");

var colorSets = [
	['#a9000c', '#011091', '#d7c8dd', '#ad6933', '#00982f'],
	null
];
var range = [];
if (current_range) {
	range.push(parseFloat(current_range[1]));
	range.push(parseFloat(current_range[2]));
}
else {
	range = [ (Date.now() - 86400000), Date.now() ];
}
console.log(range);
var reload_time = Date.now();
var g;
var drawGraph = function(data) {
	g = new Dygraph(
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
			dateWindow: range,
			unhighlightCallback: function(e) {
				range = g.xAxisRange();
				console.log('unhighlightCallback: ' + range);
				if (isNaN(range[0]) || isNaN(range[1]) || (range[0] >= range[1])) {
					console.log('range out of bounds: ' + range);
					range = [ (Date.now() - 86400000), Date.now() ];
					g.updateOptions( { dateWindow: range } );								
				}
				window.history.replaceState("", "", current_url + "#" + range[0] + "-" + range[1]);
			},
			zoomCallback: function(minDate, maxDate, yRanges) {
				range = g.xAxisRange();
				console.log('zoomCallback: ' + range);
				if (isNaN(range[0]) || isNaN(range[1]) || (range[0] >= range[1])) {
					console.log('range out of bounds: ' + range);
					range = [ (Date.now() - 86400000), Date.now() ];
					g.updateOptions( { dateWindow: range } );								
				}
				window.history.replaceState("", "", current_url + "#" + range[0] + "-" + range[1]);
			},
			clickCallback: function(e, x, points) {
				range = g.xAxisRange();
				console.log('clickCallback: ' + range);
				if (isNaN(range[0]) || isNaN(range[1]) || (range[0] >= range[1])) {
					console.log('range out of bounds: ' + range);
					range = [ (Date.now() - 86400000), Date.now() ];
					g.updateOptions( { dateWindow: range } );								
				}
				window.history.replaceState("", "", current_url + "#" + range[0] + "-" + range[1]);
			}
		}
	);
	g.ready(function () {
		console.log('range: ' + g.xAxisRange());
	});
}

var data_url_new = 'data/' + meter_serial + '/new_range';
var data_url_old = 'data/' + meter_serial + '/old_range';
var data_new = '';
var data_old = '';

var xhttp_old = new XMLHttpRequest();
xhttp_old.onreadystatechange = function() {
	if (xhttp_old.readyState == 4 && xhttp_old.status == 200) {
		// stop spinner
		spinner.stop();
		
		data_old = xhttp_old.responseText;
		drawGraph(data_old + data_new);
	}
}

var xhttp_new = new XMLHttpRequest();
xhttp_new.onreadystatechange = function() {
	if (xhttp_new.readyState == 4 && xhttp_new.status == 200) {
		data_new = xhttp_new.responseText;
		xhttp_old.open('GET', data_url_old, true);
		xhttp_old.send();
	}
}
xhttp_new.open('GET', data_url_new, true);
xhttp_new.send();

setInterval(function() {
	// update data and pan right
	console.log("update data and pan right");
	var xhttp_old = new XMLHttpRequest();
	xhttp_old.onreadystatechange = function() {
		if (xhttp_old.readyState == 4 && xhttp_old.status == 200) {
			data_old = xhttp_old.responseText;

			var reload_time_diff = Date.now() - reload_time;
			reload_time = Date.now();
			range[0] += reload_time_diff;
			range[1] += reload_time_diff;
			g.updateOptions( { file: data_old + data_new, dateWindow: range } );

			window.history.replaceState("", "", current_url + "#" + range[0] + "-" + range[1]);
		}
	}

	var xhttp_new = new XMLHttpRequest();
	xhttp_new.onreadystatechange = function() {
		if (xhttp_new.readyState == 4 && xhttp_new.status == 200) {
			data_new = xhttp_new.responseText;
			xhttp_old.open('GET', data_url_old, true);
			xhttp_old.send();
		}
	}
	xhttp_new.open('GET', data_url_new, true);
	xhttp_new.send();
	
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
	g.setVisibility(parseInt(el.id), el.checked);
}

