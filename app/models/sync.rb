require 'cgi'

class Sync

  # Syncs the mp3s in AUDIO_DIR to a mysql databases

  @hostname = ""
  @mp3_count = 0
  @mp3_processed = 0

  def self.refresh(mode, hostname)
    @mp3_count = 0
    @mp3_processed = 0

    @hostname = hostname

    stats = {
      :added => 0,
      :existing => 0,
      :moved => 0,
      :error => 0,
      :removed => 0,
      :total => 0
    }
    existing = Mp3.where("mode = '#{mode}'")

    # Create hash of mp3s and folders, used for dupe-checking
    hsh_existing_path = {}
    hsh_existing_md5 = {}
    to_delete = []
    existing.each do |mp3|
      hsh_existing_path[mp3.path] = mp3
      hsh_existing_md5[mp3.md5] = mp3
      if !File.exist?(mp3.path)
        to_delete.push(mp3)
      end
    end

    arr = [hsh_existing_path, hsh_existing_md5, to_delete]

    case mode
    when "music", "spoken"
      folders = Folder.where("mode = '#{mode}'")
      folders_hsh = {}
      folders.each do |fold|
        if Dir.exist? fold.full_path
          folders_hsh[fold.full_path] = fold
        else # Folder was removed or renamed, remove from DB. A new folder record will be created if it was renamed
          fold.destroy()
        end
      end

      parse_dir_mp3(mode, arr, stats, "#{$audio_dir}/#{mode}", -1)

      recursive_count_folder("#{$audio_dir}/#{mode}")
      recursive_sync_folder("#{$audio_dir}/#{mode}", -1, mode, folders_hsh, arr, stats)
      #sql = "
      #  DELETE FROM folders WHERE id NOT IN (SELECT folder_id FROM mp3s)
      #"
      #ActiveRecord::Base.connection.execute(sql)
    when "white-noise"
      parse_dir_mp3(mode, arr, stats, "#{$audio_dir}/white-noise")
    end

    # File doesn't exist on disk or elsewhere in DB, delete its record
    to_delete.each do |mp3|
      mp3.destroy()
    end
    stats[:removed] = to_delete.length
    Rails.logger.warn("WE NEED TO DELETE: #{to_delete}")

    stats[:total] = stats[:existing] + stats[:added]

    return stats
  end

  def self.escape_glob(s)
    s.gsub(/[\\\{\}\[\]\*\?]/) { |x| "\\"+x }
  end

  def self.recursive_count_folder(path)
    puts "recursive_count_folder: #{path}"
    Dir.glob(escape_glob(path) + "/*").each do |dir|
      next unless File.directory? dir
      @mp3_count += Dir.glob(escape_glob(dir) + "/*.mp3").count
      recursive_count_folder(dir)
    end
  end


  def self.recursive_sync_folder(path, parent_id, mode, folders_hsh, arr, stats)
    puts "recursive_sync_folder: #{path}"
    Dir.glob(escape_glob(path) + "/*").each do |dir|
      next unless File.directory? dir
    puts "dir #{dir}"
      if folders_hsh[dir]
        fold = folders_hsh[dir]
      else
        fold = Folder.create(:parent_folder_id => parent_id, :full_path => dir, :basename => File.basename(dir), :mode => mode)
      end
      folder_id = fold.id
      parse_dir_mp3(mode, arr, stats, dir, folder_id)
      recursive_sync_folder(dir, folder_id, mode, folders_hsh, arr, stats)
    end
  end

  def self.parse_dir_mp3(mode, arr, stats, path, folder_id = nil)
    puts "parse_dir_mp3: #{path}/*.mp3"
    hsh_existing_path = arr[0]
    hsh_existing_md5 = arr[1]
    to_delete = arr[2]

    mp3s = Dir.glob(escape_glob(path) + "/*.mp3")
    mp3s.each do |mp3|
      puts "MP3: #{mp3}"
      if hsh_existing_path[mp3]
        stats[:existing] += 1
        #puts "Already in DB: #{mp3}"
      else
        md5 = Digest::MD5.hexdigest(File.read(mp3))
        attrs = get_attributes(mode, mp3, md5, folder_id)
        if attrs.nil?
          stats[:error] += 1
          Rails.logger.warn("== Could not read file information: #{mp3}. Not an MP3?")
        else
          mp3 = hsh_existing_md5[md5]

          # URL changed? Make sure we can still hit it. Prevents mp3s from being added if they've got characters so weird the CGI.escape() can't convert them
          #if mp3 && attrs[:url] != mp3.url
          #  cmd = "curl -s --head -w %{http_code} http://192.168.0.103:4040/#{attrs[:url]}"
          #  exists = `#{cmd}`
          #  if !exists.match(/200 OK/)
          #    stats[:error] += 1
          #    Rails.logger.warn("== Could not hit URL: #{attrs[:url]}. Filename contains weird characters?")
          #    return
          #  end
          #end

          if mp3 && !File.exist?(mp3.path)
            stats[:moved] += 1
            puts "Mp3 has been moved or renamed, updating record #{mp3.id} for new location"
            mp3.update_attributes(attrs)
            to_delete.delete(mp3) # Since the file was only moved, don't remove its record
          else
            stats[:added] += 1
            puts "Adding new mp3 to DB: #{mp3}"
            Mp3.create(attrs)
          end
        end
      end
    end
    @mp3_processed += mp3s.count
    self.broadcast()
  end

  # Read id3 tags, return hash of all attributes
  def self.get_attributes(mode, path, md5, folder_id)
    TagLib::FileRef.open(path) do |fileref|
      if fileref.null?
        return nil
      else
        tag = fileref.tag

        url = path.sub(/^#{$audio_dir}/, "") # Remove file system path
        url = CGI.escape(url) # Url encode folder and mp3 name
        url = url.gsub(/\+/, '%20')  # Not sure why this is necessary, but whatevs
        url = '/audio' + url

        return {
          :mode => mode,
          :rank => 0,
          :title => tag.title,
          :album => tag.album,
          :track_nr => tag.track,
          :artist => tag.artist,
          :year => tag.year,
          :genre => tag.genre,
          :length_seconds => fileref.audio_properties.length,
          :folder_id => folder_id,
          :path => path,
          :filename => File.basename(path),
          :url => url,
          :md5 => md5
        }
      end
    end  # File is automatically closed at block end
  end

  def self.broadcast()
    ActionCable.server.broadcast "sync", { total: @mp3_count, current: @mp3_processed }
  end


end