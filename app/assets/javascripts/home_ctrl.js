multiroomApp.controller('HomeCtrl', function ($scope, $routeParams, $route, $rootScope, Device, Media, Preset) {

  function init() {
    $scope.home = {
      mode: '',
      devices: [],
      device: null,
      devices_loaded: false,
      mp3s: [],
      radio_stations: []
    }

    // 
    $scope.state_local = {
      mode: "",
      repeat: "off",  // off, all, one
      shuffle: "off",
      folder_id: -1,
      radio_station: ""
    }

    $scope.state_shared = []

    // Get devices, set current device if any

    // Subscribe to state channel. This shares the state of what's playing on which cast
    App.cable.subscriptions.create('StateChannel', {
      connected: function() {
        console.log("Connected to ActionCable: STATE")
      },
      received: function(data) {
        console.log("STATE", data)
        $scope.state_shared = JSON.parse(data || "[]")
        $scope.safeApply()
      },
      disconnected: function() {
        console.log("Disconnected!")
      },
      status: function() {
        console.log("STATUS")
      }
    });

    // Subscribe to devices channel. This shares the state of the cast list between users: audio casts, groups and their volume levels
    App.cable.subscriptions.create('DeviceChannel', {
      connected: function() {
        console.log("Connected to ActionCable: DEVICE")
      },
      received: function(data) {
        console.log('device', JSON.parse(data))
        $scope.home.devices = JSON.parse(data || "{}")

        $scope.home.devices_loaded = true

        if (localStorage.getItem('cast_uuid')) {
          $scope.state_local.cast_uuid = localStorage.getItem('cast_uuid');
        }

        var num_groups = 0;
        var num_audios = 0;
        for (var i = 0; i < $scope.home.devices.length; i++) {
          var dev = $scope.home.devices[i];
          if (dev['cast_type'] == 'group') {
            num_groups += 1;
          } else {
            num_audios += 1;
          }
        }

        var max = num_groups;
        if (num_audios > max) { max = num_audios; }
        $('#cast-select').css("height", (24 * 4) + "px")

        $scope.safeApply()
      },
      disconnected: function() {
        console.log("Disconnected!")
      },
      status: function() {
        console.log("STATUS")
      }
    });

    var mode = localStorage.getItem('mode');
    if (mode) {
      $scope.selectMode(mode || 'music')
    }
  }

  $scope.is_playing = function(type, val) {
    var shared = $scope.state_shared;
    for (var i = 0; i < shared.length; i++) {
      //console.log(type, shared[type], val)
      var cast = shared[i];
      if (cast[type] == val) {
        return cast;
      }
    }
    return false;
  }

  function set_default_music_folder() {
    var folder_id = localStorage.getItem('folder::music')
    if (folder_id) {
      $scope.select_folder(folder_id);
    } else {
      $scope.select_folder(-1);
    }
  }

  $scope.selectMode = function(mode, callback) {
    localStorage.setItem('mode', mode);

    $scope.state_local.mode = mode

    $scope.home.mp3s = [];

    if (mode == 'presets') {
      Preset.get_all(function(response) {
        $scope.home.presets = response.data;
        if ($scope.home.presets.length == 0) {
          $.notify("No presets found. Try playing some audio and click", "warn")
        }
        console.log(response)
      })
      if (callback) { callback() }
    }
    if (mode == 'white-noise') {
      Media.get('white-noise', -1, function(response) {
        if (response.data.length == 0) {
          $.notify("No mp3s found in this folder. You may need to populate and/or refresh your media.", "warn")
        }
        $scope.home.mp3s = response.data
        $scope.player.init($scope.home.mp3s)
        if (callback) { callback() }
      })
    }
    if (mode == 'music' || mode == 'spoken') {
      Media.get_folders(mode, -1, function(response) {
        $scope.home.folders = response.data;
        if (response.data.length == 0) {
          $.notify("No mp3s found. You may need to populate and/or refresh your media.", "warn")
        }
        set_default_music_folder()
        if (callback) { callback() }
      })
    }
    if (mode == 'radio') {
      Media.get_radio(function(response) {
        $scope.home.radio_stations = response.data;
        if ($scope.home.radio_stations.length == 0) {
          $.notify("No radio stations found. Please configure public/audio/radio.json", "warn")
        }
        console.log(response)
      })
      if (callback) { callback() }
    }
  }


  $scope.get_folder_by_id = function(folder_id) {
    Media.get_folders($scope.state_local.mode, folder_id, function(response) {
      $scope.home.folders = response.data;
      $scope.state_local.folder_id = folder_id;
    })
  }

  $scope.cur_folder = function() {
    for (var i = 0; i < $scope.home.folders.length; i++) {
      var fol = $scope.home.folders[i];
      if (fol.id == $scope.state_local.folder_id) {
        return fol;
      }      
    }
  }

  $scope.select_folder = function(folder_id) {
    localStorage.setItem('folder::' + $scope.state_local.mode, folder_id);

    $scope.state_local.folder_id = folder_id;
    Media.get($scope.state_local.mode, folder_id, function(response) {
      if (response.data.length > 0) {
        $scope.home.mp3s = response.data
        $scope.player.init($scope.home.mp3s)
      } else {
        $scope.home.mp3s = []
      }
    })
  }

  $scope.play_radio = function(station) {
    $scope.state_local.mode = 'radio'
    $scope.state_local.radio_station = station.url
    data = {
      state_local: $scope.state_local,
      playlist: [ { id: -1, url: station.url } ]
    };
    Media.play(data, function(response) {
      $scope.buffering = false;

      // Buffering complete.
      $scope.player.playing = true;

      // Show progress bar
      console.log("resp", response)
      console.log("playing!")
    })    
  }

  $scope.play = function(index) {
    //var mp3 = $scope.home.mp3s[index];

    public_prefix = dirname(audio_dir)
    url_prefix = window.http_address

    var regex = new RegExp(RegExp.escape(public_prefix));

    var playlist = []
    var mp3s = $scope.home.mp3s;

    function add_playlist(mp3) {
      var path = mp3['path'];
      url = url_prefix + encodeURI(path.replace(regex, ''))
      url = url.replace(/'/g, '%27')

      playlist.push({
        id: mp3.id,
        url: url
      });
    }
    for (var i = index; i < mp3s.length; i++) {
      add_playlist(mp3s[i])
    }
    for (var i = 0; i < index; i++) {
      add_playlist(mp3s[i])
    }

    $scope.player.pause()
    $scope.buffering = true;

    // Buffering begins...
    var item = $scope.playlist.items[index];
    $scope.playlist.current_index = index;
    $scope.playlist.current_item = item;

    var mode = $scope.state_local.mode;
    $scope.state_local.mode = mode
    data = {
      state_local: $scope.state_local,
      playlist: playlist
    };

    Media.play(data, function(response) {
      $scope.buffering = false;
      // Buffering complete.
      $scope.player.play(index, 0, function() { })
      // Show progress bar
      console.log("resp", response)
      console.log("playing!")
    })
  }

  $scope.prev = function() {
    Media.prev($scope.state_local.cast_uuid)
  }

  $scope.next = function() {
    Media.next($scope.state_local.cast_uuid)
  }

  $scope.toggleRepeat = function() {
    switch ($scope.state_local.repeat) {
      case "off":
        $scope.state_local.repeat = "all";
        break;
      case "all":
        $scope.state_local.repeat = "one";
        break;
      case "one":
        $scope.state_local.repeat = "off";
        break;
    }
  }

  $scope.toggleShuffle = function() {
    if ($scope.state_local.shuffle == "on") {
      $scope.state_local.shuffle = "off";
    } else {
      $scope.state_local.shuffle = "on";
    }
  }

  $scope.stop = function() {
    Media.stop($scope.state_local.cast_uuid)
  }

  $scope.pause = function() {
    Media.pause($scope.state_local.cast_uuid, function(response) {
      $scope.player.pause()
    })
  }

  $scope.resume = function() {
    Media.resume($scope.state_local.cast_uuid, function(response) {
      $scope.player.resume()
    })
  }

  var timer;

  $scope.volume_change = function(device) {
    clearTimeout(timer);
    timer = setTimeout(function() {
      var val = device.volume_level;
      if (device.volume_level == 1) { val = "1.0" }
      if (device.volume_level == 0) { val = "0.0" }
      Device.volume_change(device.uuid, val)
    }, 100)
  }

  $scope.preset_create = function() {
    name = window.prompt("Please enter a playlist name", "");

    Preset.create({ "name": name }, function(response) {
      console.log("response", response)
    })
  }

  $scope.play_preset = function(id) {
    Preset.play(id)
  }

  var dirname = $scope.dirname = function(str) {
    return str.replace(/\\/g,'/').replace(/\/[^\/]*$/, '');;
  }

  var basename = $scope.basename = function(str) {
     var base = new String(str).substring(str.lastIndexOf('/') + 1); 
      if(base.lastIndexOf(".") != -1)       
          base = base.substring(0, base.lastIndexOf("."));
     return base;
  }

  init_player($scope, $rootScope);

  $scope.refresh_media = function() {
    $.notify("Beginning sync. This can take several minutes depending on how many new MP3s are found.", "error")

    Media.refresh($scope.state_local.mode, function() {
      $scope.selectMode($scope.state_local.mode);
    })
  }

  $scope.refresh_devices = function() {
    Device.refresh(function(response) {
      $scope.home.devices = response.data;
      if (response.data.audios.length == 0 && response.data.audios.groups.length == 0) {
        $.notify("No chromecast audio devices or groups found!", "error")
      }
    })
  }

  $scope.select_cast = function(device) {
    $scope.state_local.cast_uuid = device.uuid;
    localStorage.setItem('cast_uuid', device.uuid);
  }

  var cache = {}
  init()

});

