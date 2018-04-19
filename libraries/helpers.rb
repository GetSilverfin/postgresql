#
# Cookbook:: postgresql
# Library:: helpers
# Author:: David Crane (<davidc@donorschoose.org>)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include Chef::Mixin::ShellOut

module PostgresqlCookbook
  module Helpers
    #######
    # Function to truncate value to 4 significant bits, render human readable.
    # Used in server_conf resource:
    #
    # The memory settings (shared_buffers, effective_cache_size, work_mem,
    # maintenance_work_mem and wal_buffers) will be rounded down to keep
    # the 4 most significant bits, so that SHOW will be likely to use a
    # larger divisor. The output is actually a human readable string that
    # ends with "GB", "MB" or "kB" if over 1023, exactly what Postgresql
    # will expect in a postgresql.conf setting. The output may be up to
    # 6.25% less than the original value because of the rounding.
    def binaryround(value)
      # Keep a multiplier which grows through powers of 1
      multiplier = 1

      # Truncate value to 4 most significant bits
      while value >= 16
        value = (value / 2).floor
        multiplier *= 2
      end

      # Factor any remaining powers of 2 into the multiplier
      while value == 2 * (value / 2).floor
        value = (value / 2).floor
        multiplier *= 2
      end

      # Factor enough powers of 2 back into the value to
      # leave the multiplier as a power of 1024 that can
      # be represented as units of "GB", "MB" or "kB".
      if multiplier >= 1024 * 1024 * 1024
        while multiplier > 1024 * 1024 * 1024
          value = 2 * value
          multiplier = (multiplier / 2).floor
        end
        multiplier = 1
        units = 'GB'

      elsif multiplier >= 1024 * 1024
        while multiplier > 1024 * 1024
          value = 2 * value
          multiplier = (multiplier / 2).floor
        end
        multiplier = 1
        units = 'MB'

      elsif multiplier >= 1024
        while multiplier > 1024
          value = 2 * value
          multiplier = (multiplier / 2).floor
        end
        multiplier = 1
        units = 'kB'

      else
        units = ''
      end

      # Now we can return a nice human readable string.
      "#{multiplier * value}#{units}"
    end

    #######
    # Locale Configuration

    # Function to test the date order.
    # Used in recipes/config_initdb.rb to set this attribute:
    #    node.default['postgresql']['config']['datestyle']
    def locale_date_order
      # Test locale conversion of mon=11, day=22, year=33
      testtime = DateTime.new(2033, 11, 22, 0, 0, 0, '-00:00')
      #=> #<DateTime: 2033-11-22T00:00:00-0000 ...>

      # %x - Preferred representation for the date alone, no time
      res = testtime.strftime('%x')

      return 'mdy' if res.nil?

      posM = res.index('11')
      posD = res.index('22')
      posY = res.index('33')

      if posM.nil? || posD.nil? || posY.nil?
        return 'mdy'
      elsif posY < posM && posM < posD
        return 'ymd'
      elsif posD < posM
        return 'dmy'
      end
      'mdy'
    end

    #######
    # Timezone Configuration
    require 'find'

    # Function to determine where the system stored shared timezone data.
    # Used in recipes/config_initdb.rb to detemine where it should have
    # select_default_timezone(tzdir) search.
    def pg_TZDIR
      # System time zone conversions are controlled by a timezone data file
      # identified through environment variables (TZ and TZDIR) and/or file
      # and directory naming conventions specific to the Linux distribution.
      # Each of these timezone names will have been loaded into the PostgreSQL
      # pg_timezone_names view by the package maintainer.
      #
      # Instead of using the timezone name configured as the system default,
      # the PostgreSQL server uses ones named in postgresql.conf settings
      # (timezone and log_timezone). The initdb utility does initialize those
      # settings to the timezone name that corresponds to the system default.
      #
      # The system's timezone name is actually a filename relative to the
      # shared zoneinfo directory. That is usually /usr/share/zoneinfo, but
      # it was /usr/lib/zoneinfo in older distributions and can be anywhere
      # if specified by the environment variable TZDIR. The tzset(3) manpage
      # seems to indicate the following precedence:
      tzdir = nil
      if ::File.directory?('/usr/lib/zoneinfo')
        tzdir = '/usr/lib/zoneinfo'
      else
        share_path = [ENV['TZDIR'], '/usr/share/zoneinfo'].compact.first
        tzdir = share_path if ::File.directory?(share_path)
      end
      tzdir
    end

    #######
    # Function to support select_default_timezone(tzdir), which is
    # used in recipes/config_initdb.rb.
    def validate_zone(tzname)
      # PostgreSQL does not support leap seconds, so this function tests
      # the usual Linux tzname convention to avoid a misconfiguration.
      # Assume that the tzdata package maintainer has kept all timezone
      # data files with support for leap seconds is kept under the
      # so-named "right/" subdir of the shared zoneinfo directory.
      #
      # The original PostgreSQL initdb is not Unix-specific, so it did a
      # very complicated, thorough test in its pg_tz_acceptable() function
      # that I could not begin to understand how to do in ruby :).
      #
      # Testing the tzname is good enough, since a misconfiguration
      # will result in an immediate fatal error when the PostgreSQL
      # service is started, with pgstartup.log messages such as:
      # LOG:  time zone "right/US/Eastern" appears to use leap seconds
      # DETAIL:  PostgreSQL does not support leap seconds.

      if tzname.index('right/') == 0
        false
      else
        true
      end
    end

    # Function to support select_default_timezone(tzdir), which is
    # used in recipes/config_initdb.rb.
    def identify_system_timezone(tzdir)
      resultbuf = scan_available_timezones(tzdir)

      if !resultbuf.nil?
        # Ignore Olson's rather silly "Factory" zone; use GMT instead
        resultbuf = nil if (resultbuf <=> 'Factory') == 0

      else
        # Did not find the timezone.  Fallback to use a GMT zone.  Note that the
        # Olson timezone database names the GMT-offset zones in POSIX style: plus
        # is west of Greenwich.
        testtime = DateTime.now
        std_ofs = testtime.strftime('%:z').split(':')[0].to_i

        resultbuf = [
          'Etc/GMT',
          -std_ofs > 0 ? '+' : '',
          (-std_ofs).to_s,
        ].join('')
      end

      resultbuf
    end

    #######
    # Function to determine the name of the system's default timezone.
    # Used in recipes/config_initdb.rb to set these attributes:
    #    node.default['postgresql']['config']['log_timezone']
    #    node.default['postgresql']['config']['timezone']
    def select_default_timezone(tzdir)
      system_timezone = nil

      # Check TZ environment variable
      tzname = ENV['TZ']
      if !tzname.nil? && !tzname.empty? && validate_zone(tzname)
        system_timezone = tzname

      else
        # Nope, so try to identify system timezone from /etc/localtime
        tzname = identify_system_timezone(tzdir)
        system_timezone = tzname if validate_zone(tzname)
      end

      system_timezone
    end

    #######
    # Function to execute an SQL statement in the default database.
    #   Input: Query could be a single String or an Array of String.
    #   Output: A String with |-separated columns and \n-separated rows.
    #           Note an empty output could mean psql couldn't connect.
    # This is easiest for 1-field (1-row, 1-col) results, otherwise
    # it will be complex to parse the results.
    def execute_sql(query, db_name)
      # query could be a String or an Array of String
      statement = query.is_a?(String) ? query : query.join("\n")
      cmd = shell_out("psql -q --tuples-only --no-align -d #{db_name} -f -",
                      user: 'postgres',
                      input: statement)
      # If psql fails, generally the postgresql service is down.
      # Instead of aborting chef with a fatal error, let's just
      # pass these non-zero exitstatus back as empty cmd.stdout.
      if cmd.exitstatus == 0 && !cmd.stderr.empty?
        # An SQL failure is still a zero exitstatus, but then the
        # stderr explains the error, so let's rais that as fatal.
        Chef::Log.fatal("psql failed executing this SQL statement:\n#{statement}")
        Chef::Log.fatal(cmd.stderr)
        raise 'SQL ERROR'
      end
      cmd.stdout.chomp
    end

    def database_exists?(new_resource)
      sql = %(SELECT datname from pg_database WHERE datname='#{new_resource.database}')

      exists = %(psql -c "#{sql}")
      exists << " -U #{new_resource.user}" if new_resource.user
      exists << " --host #{new_resource.host}" if new_resource.host
      exists << " --port #{new_resource.port}" if new_resource.port
      exists << " | grep #{new_resource.database}"

      cmd = Mixlib::ShellOut.new(exists, user: 'postgres')
      cmd.run_command
      cmd.exitstatus == 0
    end

    def user_exists?(new_resource)
      exists = %(psql -c "SELECT rolname FROM pg_roles WHERE rolname='#{new_resource.user}'" | grep '#{new_resource.user}')

      cmd = Mixlib::ShellOut.new(exists, user: 'postgres')
      cmd.run_command
      cmd.exitstatus == 0
    end

    def role_sql(new_resource)
      sql = %(\\\"#{new_resource.user}\\\" WITH )

      %w(superuser createdb createrole inherit replication login).each do |perm|
        sql << "#{'NO' unless new_resource.send(perm)}#{perm.upcase} "
      end

      sql << if new_resource.encrypted_password
               "ENCRYPTED PASSWORD '#{new_resource.encrypted_password}'"
      elsif new_resource.password
        "PASSWORD '#{new_resource.password}'"
      else
        ''
      end

      sql << if new_resource.valid_until
               " VALID UNTIL '#{new_resource.valid_until}'"
      else
        ''
      end
    end

    def extension_installed?
      query = "SELECT 'installed' FROM pg_extension WHERE extname = '#{new_resource.extension}';"
      !(execute_sql(query, new_resource.database) =~ /^installed$/).nil?
    end

    def data_dir(version = node.run_state['postgresql']['version'])
      case node['platform_family']
      when 'rhel', 'fedora', 'amazon'
        "/var/lib/pgsql/#{version}/data"
      when 'debian'
        "/var/lib/postgresql/#{version}/main"
      end
    end

    def conf_dir(version = node.run_state['postgresql']['version'])
      case node['platform_family']
      when 'rhel', 'fedora', 'amazon'
        "/var/lib/pgsql/#{version}/data"
      when 'debian'
        "/etc/postgresql/#{version}/main"
      end
    end

    # determine the platform specific service name
    def platform_service_name(version = node.run_state['postgresql']['version'])
      if %w(rhel amazon fedora).include?(node['platform_family'])
        "postgresql-#{version}"
      else
        'postgresql'
      end
    end

    def psql_command_string(database, query)
      "psql -d #{database} <<< '\\set ON_ERROR_STOP on\n#{query};'"
    end

    def slave?
      ::File.exist? "#{data_dir}/recovery.conf"
    end
  end
end
