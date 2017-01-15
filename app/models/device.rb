class Device
  require 'benchmark'

  attr_accessor :uuid, :cast_type, :friendly_name, :volume_level, :status_text, :model_name, :state_local, :playlist, :playlist_index

  @uuid = ""
  @cast_type = ""
  @friendly_name = ""
  @volume_level = ""
  @status_text = ""
  @model_name = ""
  @state_local = ""
  @playlist = []
  @playlist_index = 0

  def initialize(hsh)
    @uuid = hsh["uuid"]
    @cast_type = hsh["cast_type"]
    @friendly_name = hsh["friendly_name"]
    @volume_level = hsh["volume_level"]
    @status_text = hsh["status_text"]
    @model_name = hsh["model_name"]
    @state_local = hsh["state_local"] || {}
    @playlist = hsh["playlist"] || []
    @playlist_index = 0
  end

  def cast_var()
    "casts_by_uuid['#{@uuid}']"
  end

  def children
    cur = {
      '5a7082bf-0f52-4d1c-8453-58bdf657c0fa' => [ '1bb851ea-5b0a-fce7-f395-16e1e13a86b9', 'a8a9ee5a-26df-595c-c566-c46b19006f7f' ],
      '8f0c4659-3ef2-4155-bdcf-da6176c41f62' => [ '72af5e77-b9c9-150a-9372-f613c16698b8' ],
      'ebdea152-4479-41c8-af85-5b3b0231c9e2' => [ '72af5e77-b9c9-150a-9372-f613c16698b8', 'a8a9ee5a-26df-595c-c566-c46b19006f7f', '1bb851ea-5b0a-fce7-f395-16e1e13a86b9' ]
    }
    return cur[@uuid] || []
  end

  def select()
    str = %Q{
      #{cast_var}.wait()
    }
    PyChromecast.run(str)
  end

  # Get all devices from cache
  #def self.get_all()
  #  str = $redis.get("devices") 
  #  if str.blank? # Redis got cleared or some such, repopulate devices
  #    self.refresh()
  #    str = $redis.get("devices")
  #  end
  #  # {"uuid"=>"ebdea152-4479-41c8-af85-5b3b0231c9e2", "cast_type"=>"group", "friendly_name"=>"ALL", "volume_level"=>0.8125, "status_text"=>"", "model_name"=>"Google Cast Group"}
  #  return JSON.load(devices)
  #end

  # Refresh list of devices and save to cache
  def self.refresh()

    # Without this sleep, the cc.status calls will fail with: "AttributeError: 'NoneType' object has no attribute 'status_text'"
    # I'm making it configurable here in case others require a longer sleep
    sleep_before_status = 1 

    $get_devices = "
chromecasts = pychromecast.get_chromecasts()
time.sleep(#{sleep_before_status})
arr = [ { u'friendly_name': cc.device.friendly_name, u'model_name': cc.device.model_name, 'uuid': cc.device.uuid.urn[9:], 'cast_type': cc.device.cast_type, 'status_text': cc.status.status_text, 'volume_level': cc.status.volume_level } for cc in chromecasts]
print(json.dumps(arr))
"
    all = PyChromecast.run($get_devices)

$init_casts_by_uuid = "
casts_by_uuid = {}
print('Number of casts:')
print(len(chromecasts))
"
    PyChromecast.run($init_casts_by_uuid)

$populate_casts_var = "for cc in chromecasts:
  cc.wait()
  casts_by_uuid[cc.uuid.urn[9:]] = cc

"
    PyChromecast.run($populate_casts_var, false, false)

    PyChromecast.run("print(casts_by_uuid)")

    devs = JSON.parse(all)
    if devs.length == 0
      raise "No chromecast audio devices found on the network! Please set up your chromecasts and try again."
    end
    $redis.set("devices", JSON.dump(devs))

    $devices = []
    devs.each do |hsh|
      $devices.push(Device.new(hsh)) if hsh["cast_type"] == "group" || hsh["cast_type"] == "audio"
    end

    stop_all() # Since the threads which monitored the casts will have died if we're here, we have no idea what they're playing. Stop all casts from playing for sanity's sake.

    buffering_pause = 3

    $devices.each do |device|
      uuid = device.uuid
      $threads[uuid] = Thread.new do
        begin
          while(true) do
            cmd = ""
            $semaphore.synchronize {
              cmd = $redis.hget("thread_command", uuid)
              puts "uuid: #{uuid}, cmd: #{cmd}"
            }

            case cmd
            when "play" # See: mp3s_controller.rb#play
              # User clicked play

              if device.cast_type == "group"
                device.children.each do |child_uuid|
                  puts "====+++++ CHILD #{child_uuid}"
                  child = Device.get_by_uuid(child_uuid)
                  child.stop()
                end
                Device.broadcast()
              end

              device.playlist_index = 0
              device.play_at_index()
            when "wait_for_idle"
              # When the cast goes from BUFFERING/PLAYING to IDLE, that means the song has ended or couldn't be played. Move on to the next item in the playlist
              if device.player_status() == "IDLE"
                continue_playing = true
                device.playlist_index += 1
                if device.state_local[:repeat] == "one"
                  device.playlist_index = 0
                end
                if device.playlist_index >= device.playlist.length # Reached the end of the playlist
                  if device.state_local[:repeat] == "all"
                    device.playlist_index = 0
                  else # Repeat isn't on, just stop playing
                    continue_playing = false
                    Device.broadcast() # Inform user playlist is done playing
                  end
                end
                device.play_at_index() if continue_playing
              end
            when "next"
              device.playlist_index += 1
              device.playlist_index = 0 if device.playlist_index >= device.playlist.length
              device.play_at_index()
            when "prev"
              device.playlist_index -= 1
              device.playlist_index = device.playlist.length - 1 if device.playlist_index < 0
              device.play_at_index()
            end
            sleep 1
          end
        rescue Exception => ex
          puts "================EXCEPTION==============

#{ex.inspect}

================/EXCEPTION=============="
        end
      end
    end

  end

  MAX_BUFFERING_WAIT = 10
  MAX_PLAYING_WAIT = 8
  RETRY_WAIT = 5
  MAX_RETRIES = 3

  def play_at_index(retry_num = 0)
    puts "Playlist index: #{@playlist_index}"
    mp3 = @playlist[@playlist_index]

    @state_local[:mp3_id] = mp3[:id]
    @state_local[:mp3_url] = mp3[:url]

    play_url(mp3[:url])
    sleep(0.5)
    if wait_for_device_status('BUFFERING', 0.5, MAX_BUFFERING_WAIT) # Wait 10 seconds to go from IDLE/UNKNOWN -> BUFFERING
      if wait_for_device_status('PLAYING', 0.5, MAX_PLAYING_WAIT) # Wait 5 seconds to go from BUFFERING -> PLAYING
        $redis.hset("thread_command", @uuid, "wait_for_idle") # Wait indefinitely for "IDLE" status a.k.a. MP3 has stopped playing
        return true
      else
        # Could not get MP3
        Rails.logger.warn("= 102 = Could not retrieve buffer for mp3 within #{MAX_PLAYING_WAIT}. Waiting #{RETRY_WAIT} seconds and retrying. Retry ##{retry_num + 1} of #{MAX_RETRIES} for #{mp3[:url]}")
        sleep(RETRY_WAIT)  # Wait 5 seconds and try again
        if retry_num < MAX_RETRIES
          return play_at_index(retry_num + 1)
        else
          Rails.logger.error("= 101 = Tried #{MAX_RETRIES} times and couldn't go from BUFFERING to PLAYING - give up and cancel play")
          $redis.hset("thread_command", @uuid, "")
          return false
        end
      end
    else
      Rails.logger.error("= 103 = Couldn't download/buffer mp3 in #{MAX_BUFFERING_WAIT} seconds. Canceling play.")
      $redis.hset("thread_command", @uuid, "")
      return false
    end
  end

  def wait_for_device_status(str, interval = 0.5, max_wait = 5)
    player_state = ""
    reps = 0
    while (player_state != str && reps * interval < max_wait)
      reps += 1
      puts "Waiting for...#{str}"
      player_state = player_status()
      sleep(interval) # Poll device every half second
    end
    if reps * interval >= max_wait # Timed out waiting for status
      return false
    end
    Device.broadcast()  # Inform users this cast is buffering
    return true
  end

  def self.get_by_uuid(uuid)
    $devices.each do |dev|
      return dev if dev.uuid == uuid
    end
    nil
  end

  def self.stop_all(broadc = false)
    $devices.each do |dev|
      dev.stop()
      $redis.hset("thread_command", dev.uuid, "")
    end

    all_stopped = false
    reps = 0
    max_reps = 0.5 * 2 * 30 # Wait a max of 30 seconds for all devices to stop playing
    while !all_stopped
      all_stopped = true
      $devices.each do |dev|
        stat = dev.player_status
        all_stopped = false if stat == "PLAYING"
      end
      sleep 0.5
      reps += 1
      if reps >= max_reps
        raise "Could not stop all devices!"
      end
    end

    Device.broadcast() if broadc
  end

  def cast_status
    str = %Q{
      print(#{cast_var}.status.status_text)
    }
    PyChromecast.run(str)
  end

  def player_status
    #  cast = next(cc for cc in chromecasts if cc.device.uuid.urn == "urn:uuid:#{uuid}")
    #  cast.wait()
    str = %Q{
      print(#{cast_var}.media_controller.status.player_state)
    }
    PyChromecast.run(str)
  end

  def play_url(url)
    str = %Q{
      #{cast_var}.media_controller.play_media('#{url}', 'audio/mp3')
    }
    PyChromecast.run(str)

  end

  def play()

  end

  def stop()
    str = %Q{
      #{cast_var}.media_controller.stop()
    }
    PyChromecast.run(str)

    # This clears what's playing on front-end
    @state_local['mode'] = ""
    @state_local['folder_id'] = nil
    @state_local['mp3_url'] = ""
    @state_local['mp3_id'] = nil
    @state_local['radio_station'] = nil
  end

  def pause()
    str = %Q{
      #{cast_var}.media_controller.pause()
    }
    PyChromecast.run(str)
    wait_for_device_status("PAUSED", 0.1)
    Device.broadcast()
  end

  def resume()
    str = %Q{
      #{cast_var}.media_controller.play()
    }
    PyChromecast.run(str)
    wait_for_device_status("PLAYING", 0.1)
    Device.broadcast()
  end

  def set_volume(level)
    str = %Q{
      #{cast_var}.set_volume(#{level})
    }
    PyChromecast.run(str)

    @volume_level = level.to_f

    Device.broadcast()
  end

  def to_h
    {
      uuid: @uuid,
      cast_type: @cast_type,
      friendly_name: @friendly_name,
      volume_level: @volume_level,
      status_text: @status_text,
      model_name: @model_name,
      state_local: @state_local,
      player_status: player_status()
    }
  end

  def self.broadcast()
    arr = []
    num_casting = -1
    $devices.each do |dev|
      hsh = dev.to_h()
      if hsh[:player_status] == 'BUFFERING' || hsh[:player_status] == 'PLAYING'
        num_casting += 1
        hsh[:num_casting] = num_casting
      end
      arr.push(hsh)
    end
    ActionCable.server.broadcast "device", JSON.dump(arr)
  end

end