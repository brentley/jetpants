module Jetpants
  
  # Topology maintains a list of all DB pools/shards, and is responsible for
  # reading/writing configurations and manages spare box assignments.
  # Much of this behavior needs to be overridden by a plugin to actually be
  # useful.  The implementation here is just a stub.
  class Topology
    attr_reader :pools
    
    def initialize
      @pools  = [] # array of Pool objects
      # We intentionally don't call load_pools here. The caller must do that.
      # This allows Jetpants module to create Jetpants.topology object, and THEN
      # invoke load_pools, which might then refer back to Jetpants.topology.
    end
    
    ###### Class methods #######################################################
    
    # Metaprogramming hackery to create a "synchronized" method decorator
    # Note that all synchronized methods share the same mutex, so don't make one
    # synchronized method call another!
    @lock = Mutex.new
    @do_sync = false
    @synchronized_methods = {} # symbol => true
    class << self
      # Decorator that causes the next method to be wrapped in a mutex
      # (only affects the next method definition, not ALL subsequent method
      # definitions)
      # If the method is subsequently overridden by a plugin, the new version
      # will be synchronized as well, even if the decorator is omitted.
      def synchronized
        @do_sync = true
      end
      
      def method_added(name)
        if @do_sync || @synchronized_methods[name]
          lock = @lock
          @do_sync = false
          @synchronized_methods[name] = false # prevent infinite recursion from the following line
          alias_method "#{name}_without_synchronization".to_sym, name
          define_method name do |*args|
            result = nil
            lock.synchronize {result = send "#{name}_without_synchronization".to_sym, *args}
            result
          end
          @synchronized_methods[name] = true # remember it is synchronized, to re-apply wrapper if method overridden by a plugin
        end
      end
    end
    
    
    ###### Overrideable methods ################################################
    # Plugins should override these if the behavior is needed. (Note that plugins
    # don't need to repeat the "synchronized" decorator; it automatically
    # applies to overrides.)
    
    synchronized
    # Plugin should override so that this reads in a configuration and initializes
    # @pools as appropriate.
    def load_pools
      puts "\nNotice: no plugin has overridden Topology#load_pools, so no pools are imported automatically"
    end
    
    synchronized
    # Plugin should override so that it writes a configuration file or commits a
    # configuration change to a config service.
    def write_config
      puts "\nNotice: no plugin has overridden Topology#write_config, so configuration data is not saved"
    end
    
    synchronized
    # Plugin should override so that this returns an array of [count] Jetpants::DB
    # objects, or throws an exception if not enough left.
    # Options hash is plugin-specific. The only assumed option used by the rest of
    # Jetpants is :role of 'MASTER' or 'STANDBY_SLAVE', for grabbing hardware
    # suited for a particular purpose. This can be ignored if your hardware is
    # entirely uniform and/or a burn-in process is already performed on all new
    # hardware intakes.
    def claim_spares(count, options={})
      raise "Plugin must override Topology#claim_spares"
    end
    
    synchronized
    # Plugin should override so that this returns a count of spare machines
    # matching the selected options.
    def count_spares(options={})
      raise "Plugin must override Topology#count_spares"
    end
    
    # Returns a list of valid role symbols in use in Jetpants.
    def valid_roles
      [:master, :active_slave, :standby_slave, :backup_slave]
    end
    
    # Returns a list of valid role symbols which indicate a slave status
    def slave_roles
      valid_roles.reject {|r| r == :master}
    end
    
    ###### Instance Methods ####################################################
    
    # Returns array of this topology's Jetpants::Pool objects of type Jetpants::Shard
    def shards
      @pools.select {|p| p.is_a? Shard}
    end
    
    # Returns array of this topology's Jetpants::Pool objects that are NOT of type Jetpants::Shard
    def functional_partitions
      @pools.reject {|p| p.is_a? Shard}
    end
    
    # Finds and returns a single Jetpants::Pool. Target may be a name (string) or master (DB object).
    def pool(target)
      if target.is_a?(DB)
        @pools.select {|p| p.master == target}.first
      else
        @pools.select {|p| p.name == target}.first
      end
    end
    
    # Finds and returns a single Jetpants::Shard. Pass in one of these:
    # * a min ID and a max ID
    # * just a min ID
    # * a Range object
    def shard(*args)
      if args.count == 2 || args[0].is_a?(Array)
        args.flatten!
        args.map! {|x| x.to_s.upcase == 'INFINITY' ? 'INFINITY' : x.to_i}
        shards.select {|s| s.min_id == args[0] && s.max_id == args[1]}.first
      elsif args[0].is_a?(Range)
        shards.select {|s| s.min_id == args[0].min && s.max_id == args[0].max}.first
      else
        result = shards.select {|s| s.min_id == args[0].to_i}
        raise "Multiple shards found with that min_id!" if result.count > 1
        result.first
      end
    end
    
    # Returns the Jetpants::Shard that handles the given ID.
    def shard_for_id(id)
      shards.select {|s| s.min_id <= id && (s.max_id == 'INFINITY' || s.max_id >= id)}[0]
    end
    
    # Returns the Jetpants::DB that handles the given ID with the specified
    # mode (either :read or :write)
    def shard_db_for_id(id, mode=:read)
      shard_for_id(id).db(mode)
    end
    
    # Nicer inteface into claim_spares when only one DB is desired -- returns
    # a single Jetpants::DB object instead of an array.
    def claim_spare(options={})
      claim_spares(1, options)[0]
    end
    
    # Returns if the supplied role is valid
    def valid_role? role
      valid_roles.include? role.to_s.downcase.to_sym
    end
    
    # Converts the supplied roles (strings or symbols) into lowercase symbol versions
    # Will expand out special role of :slave to be all slave roles.
    def normalize_roles(*roles)
      roles = roles.flatten.map {|r| r.to_s.downcase == 'slave' ? slave_roles.map(&:to_s) : r.to_s.downcase}.flatten
      roles.each {|r| raise "#{r} is not a valid role" unless valid_role? r}
      roles.uniq.map &:to_sym
    end
    
    synchronized
    # Clears the pool list and nukes cached DB and Host object lookup tables
    def clear
      @pools = []
      DB.clear
      Host.clear
    end
    
    # Empties and then reloads the pool list
    def refresh
      clear
      load_pools
      true
    end
  end
end
