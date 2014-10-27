require 'puppet'
require 'puppet/indirector'
require 'puppet/file_serving'
require 'puppet/file_serving/base'
require 'puppet/util/checksums'

# A class that handles retrieving file metadata.
class Puppet::FileServing::Metadata < Puppet::FileServing::Base

  include Puppet::Util::Checksums

  extend Puppet::Indirector
  indirects :file_metadata, :terminus_class => :selector

  attr_reader :path, :owner, :group, :mode, :checksum_type, :checksum, :ftype, :destination

  PARAM_ORDER = [:mode, :ftype, :owner, :group]

  def checksum_type=(type)
    raise(ArgumentError, "Unsupported checksum type #{type}") unless Puppet::Util::Checksums.respond_to?("#{type}_file")

    @checksum_type = type
  end

  class MetaStat
    extend Forwardable

    def initialize(stat, source_permissions = nil)
      @stat = stat
      @source_permissions_ignore = (!source_permissions || source_permissions == :ignore)
    end

    def owner
      @source_permissions_ignore ? Process.euid : @stat.uid
    end

    def group
      @source_permissions_ignore ? Process.egid : @stat.gid
    end

    def mode
      @source_permissions_ignore ? 0644 : @stat.mode
    end

    def_delegators :@stat, :ftype
  end

  class WindowsStat < MetaStat
    if Puppet.features.microsoft_windows?
      require 'puppet/util/windows/security'
    end

    def initialize(stat, path, source_permissions = nil)
      super(stat, source_permissions)
      @path = path
      raise(ArgumentError, "Unsupported Windows source permissions option #{source_permissions}") unless @source_permissions_ignore
    end

    { :owner => 'S-1-5-32-544',
      :group => 'S-1-0-0',
      :mode => 0644
    }.each do |method, default_value|
      define_method method do
        return default_value
      end
    end
  end

  def collect_stat(path, source_permissions)
    stat = stat()

    if Puppet.features.microsoft_windows?
      WindowsStat.new(stat, path, source_permissions)
    else
      MetaStat.new(stat, source_permissions)
    end
  end

  # Retrieve the attributes for this file, relative to a base directory.
  # Note that Puppet::FileSystem.stat(path) raises Errno::ENOENT
  # if the file is absent and this method does not catch that exception.
  def collect(source_permissions = nil)
    real_path = full_path

    stat = collect_stat(real_path, source_permissions)
    @owner = stat.owner
    @group = stat.group
    @ftype = stat.ftype

    # We have to mask the mode, yay.
    @mode = stat.mode & 007777

    case stat.ftype
    when "file"
      @checksum = ("{#{@checksum_type}}") + send("#{@checksum_type}_file", real_path).to_s
    when "directory" # Always just timestamp the directory.
      @checksum_type = "ctime"
      @checksum = ("{#{@checksum_type}}") + send("#{@checksum_type}_file", path).to_s
    when "link"
      @destination = Puppet::FileSystem.readlink(real_path)
      @checksum = ("{#{@checksum_type}}") + send("#{@checksum_type}_file", real_path).to_s rescue nil
    else
      raise ArgumentError, "Cannot manage files of type #{stat.ftype}"
    end
  end

  def initialize(path,data={})
    @owner       = data.delete('owner')
    @group       = data.delete('group')
    @mode        = data.delete('mode')
    if checksum = data.delete('checksum')
      @checksum_type = checksum['type']
      @checksum      = checksum['value']
    end
    @checksum_type ||= Puppet[:digest_algorithm]
    @ftype       = data.delete('type')
    @destination = data.delete('destination')
    super(path,data)
  end

  def to_data_hash
    super.update(
      {
        'owner'        => owner,
        'group'        => group,
        'mode'         => mode,
        'checksum'     => {
          'type'   => checksum_type,
          'value'  => checksum
        },
        'type'         => ftype,
        'destination'  => destination,

      }
    )
  end

  def self.from_data_hash(data)
    new(data.delete('path'), data)
  end

  def self.from_pson(data)
    Puppet.deprecation_warning("from_pson is being removed in favour of from_data_hash.")
    self.from_data_hash(data)
  end

end
