#TODO: add changes to pristine file to database, in "production" area 
#TODO: StagedChanges also in clear_cbac_tables

#TODO: zip (or something) the directory resulting from a snapshot and delete it
#TODO: unzip (or something) the provided snapshot and load from it, then delete temp dir
#TODO: push as much as possible from this file to the core of CBAC, since reading pristine files from the front end will be required later on as well.
#TODO: add staging area to extracted snapshot, inserted snapshot, clearing code, etc.

#TODO: keep thinking: currently, non-changes are not saved as known_permissions when using pristine or such. This seems to be OK, but keep thinking about it.

# Get a privilege set that fulfills the provided conditions
def get_privilege_set(conditions)
  Cbac::PrivilegeSetRecord.first(:conditions => conditions)
end

# Get a Hash containing all entries from the provided table
def select_all(table)
  ActiveRecord::Base.connection.select_all("SELECT * FROM %s;" % table)
end

# Generate a usable filename for dumping records of the specified type
def get_filename(type)
  "#{ENV['SNAPSHOT_NAME']}/cbac_#{type}.yml"
end

def load_objects_from_yaml(type)
  filename = get_filename(type)

  Yaml.load_file(filename)
end

# Dump the specified permissions to a YAML file
def dump_permissions_to_yaml_file(permissions)
  permissions.each do |cp|
    privilege_set_name = get_privilege_set(:id => cp['privilege_set_id']).name
    cp['privilege_set_id'] = "<%= Cbac::PrivilegeSetRecord.find(:first, :conditions => {:name => '#{privilege_set_name}'}).id %>"
  end
  dump_objects_to_yaml_file(permissions, "permissions")
end

# Dump a set of objects to a YAML file. Filename is determined by type-string
def dump_objects_to_yaml_file(objects, type)
  filename = get_filename(type)

  puts "Writing #{type} to disk"

  File.open(filename, "w") do |output_file|
    index = "0000"
    output_file.write objects.inject({}) { |hash, record|
      hash["#{type.singularize}_#{index.succ!}"] = record
      hash
    }.to_yaml
  end
end

def clear_cbac_tables
  Cbac::GenericRole.delete_all
  Cbac::Membership.delete_all
  Cbac::Permission.delete_all
  Cbac::KnownPermission.delete_all
  Cbac::StagedChange.delete_all
end

def database_contains_cbac_data?
  return (Cbac::GenericRole.count != 0 or Cbac::Membership.count != 0 or Cbac::Permission.count != 0 or Cbac::KnownPermission.count != 0 or Cbac::StagedChange.count != 0)
end

def handle_rename_privilegeset(old_set_name, new_set_name)
  #TODO: not for this version yet
end

def handle_drop_privilegeset(old_set_name)
  #TODO: not for this version yet
end

def handle_grant_permission(change)
  set_name = change[:operands][:privilege_set]
  role = change[:operands][:role]
  permission = Cbac::Permission.new
  permission.privilege_set_id = get_privilege_set(:name => set_name).id
  if role == "administrators"
    permission.generic_role_id = Cbac::GenericRole.first(:conditions => {:name => "administrators"}).id
  else
    permission.context_role = role
  end
  permission.save
end

def handle_revoke_permission(change)
  set_name = change[:operands][:privilege_set]
  role = change[:operands][:role]
  privilege_set_id = get_privilege_set(:name => set_name).id
  if role == "administrators"
    permission = Cbac::Permission.first(:conditions => {:privilege_set_id => privilege_set_id, :generic_role_id => Cbac::GenericRole.first(:conditions => {:name => "administrators"}).id}) 
  else
    permission = Cbac::Permission.first(:conditions => {:privilege_set_id => privilege_set_id, :context_role => role})
  end
  puts "set name: #{set_name} - role: #{role} - privilegeset id: #{privilege_set_id}"
  permission.destroy
end

def parse_role(operand_string)
  match_data = operand_string.match( /^\s*Admin\(\)/ )
  if match_data.nil? # this is not for the admin role
    match_data_context_role = operand_string.match( /^\s*ContextRole\(\s*([A-Za-z0-9_]+)\s*\)/ )
    if match_data_context_role.nil?
      puts "Error: PrivilegeSet expected, but found: \"#{operand_string}\". Exiting"
      exit
    else
      return match_data_context_role.captures[0], match_data_context_role.post_match
    end
  else
    return "administrators", match_data.post_match
  end
end

def parse_privilege_set(operand_string)
  match_data = operand_string.match( /^\s*PrivilegeSet\(\s*([A-Za-z0-9_]+)\s*\)\s*/ )
  if match_data.nil?
    puts "Error: PrivilegeSet expected, but found: \"#{operand_string}\". Exiting"
    exit
  else
    return match_data.captures[0], match_data.post_match
  end
end

def parse_operands(operation, operand_string)
  operands = {}
  case operation
  when "+", "-"
    operand, rest = parse_privilege_set(operand_string)
    operands[:privilege_set] = operand
    operand, rest = parse_role(rest)
    operands[:role] = operand
    if !rest.match( /^\s*\Z/ )
      puts "Error: garbage found after end of line. Exiting"
      exit
    else
      return operands
    end
  when "x"
    #TODO: add handling for this case
    puts "Found removal operation, will parse only a privilege set"
  when "=>"
    #TODO: add handling for this case
    puts "Found migration operation, will parse two privilegesets"
  else
    puts "Illegal operation encountered while parsing, exiting"
    exit
  end
end

def parse_pristine_file(filename)
  # Reading file:
  changes = []
  File.open(filename, "r") do |f|
    last_row_number = -1
    f.each_with_index do |l, linenumber|
      line = l.chomp
      if (line =~ /^\s*(\d+)\s*:\s*([\+-x]|=>)\s*:(\s*[A-Za-z]+\(\s*[A-Za-z_]*\s*\))+\s*\Z/).nil?
        unless res =~ /^\s*(#?|\s*$)/  # line is whitespace or comment line
          puts "Error: garbage found in input file on line #{linenumber + 1}"
          exit
        end # line was non-empty and non-comment, so broken
      else
        header_match = line.match( /^(\d+):([\+-x]|=>):\s*/ )
        row_number = header_match.captures[0].to_i
        if row_number != last_row_number.succ
          puts "Error: row numbers in pristine file do not increase monotonously. Exiting."
          exit
        else
          last_row_number = row_number
        end
        operation = header_match.captures[1]
        operand_string = header_match.post_match

        operands = parse_operands(operation, operand_string)
        changes << {:permission_number => row_number, :type => operation, :operands => operands}
      end # is line valid?
    end # each line in file
  end # File open block

  changes
end

def permission_exists?(action)
  privilege_set = Cbac::PrivilegeSetRecord.first(:conditions => {:name => action[:operands][:privilege_set]})
  if action[:operands][:role] == 'administrators'
    return Cbac::Permission.exists?(:generic_role_id => Cbac::GenericRole.first(:conditions => {:name => "administrators"}).id, :privilege_set_id => privilege_set.id)
  else 
    return Cbac::Permission.exists?(:context_role => action[:operands][:role], :privilege_set_id => privilege_set.id)
  end
end

def is_change?(action)
  #TODO return true if applying this action will change the database, false otherwise
  case action[:type]
  when "+"
    return !permission_exists?(action)
  when "-"
    return permission_exists?(action)
  when "x", "=>"
    throw "Not yet implemented"
  else
    throw "Error: unknown action encountered while parsing: #{action[:type]}"
  end
end

def load_changes_into_staging_area(pristine_set)
  #TODO: load all changes into the staging area
end

def load_changes_into_database(pristine_set)
  puts "Calculating changes"
  changeset = pristine_set.select do |c| is_change?(c) end
  puts "Adding changes to database"
  changeset.each do |c|
    case c[:type]
    when "+"
      handle_grant_permission(c)
    when "-"
      handle_revoke_permission(c)
    when "=>"
      handle_rename_privilegeset(c)
    when "x"
      handle_drop_privilegeset(c)
    end
    ckp = Cbac::KnownPermission.new(:permission_number => c[:permission_number])
    ckp.save
  end
  puts "Successfully loaded #{changeset.size} changes into database" if changeset.size != 0
end

namespace :cbac do
  desc 'Initialize CBAC tables with bootstrap data. Allows ADMINUSER to log in and visit CBAC administration pages. Also, if a Privilege Set called "login" exists, this privilege is granted to "everyone"'
  task :bootstrap => :environment do
    if database_contains_cbac_data?
      if ENV['FORCE'] == "true"
        puts "FORCE specified: emptying CBAC tables"
        clear_cbac_tables
      else
        puts "CBAC bootstrap failed: CBAC tables are nonempty. Specify FORCE=true to override this check and empty the tables"
        exit
      end
    end

    adminuser = ENV['ADMINUSER'] || 1
    login_privilege_set = get_privilege_set(:name => "login")
    everybody_context_role = ContextRole.roles[:everybody]
    if !login_privilege_set.nil? and !everybody_context_role.nil?
      puts "Login privilege exists. Allowing context role 'everybody' to use login privilege"
      login_permission = Cbac::Permission.new(:context_role => 'everybody', :privilege_set_id => login_privilege_set.id)
      throw "Failed to save Login Permission" unless login_permission.save
    end

    puts "Creating Generic Role: administrators"
    admin_role = Cbac::GenericRole.new(:name => "administrators", :remarks => "System administrators - may edit CBAC permissions")
    throw "Failed to save new Generic Role" unless admin_role.save

    puts "Creating Administrator Membership for user #{adminuser}"
    membership = Cbac::Membership.new(:user_id => adminuser, :generic_role_id => admin_role.id)
    throw "Failed to save new Administrator Membership" unless membership.save

    begin
      admin_privilege_set_id = get_privilege_set({:name => 'cbac_administration'}).id
    rescue
      throw "No PrivilegeSet cbac_administration defined. Aborting."
    end
    cbac_admin_permission = Cbac::Permission.new(:generic_role_id => admin_role.id, :privilege_set_id => admin_privilege_set_id)
    throw "Failed to save Cbac_Administration Permission" unless cbac_admin_permission.save

    # TODO: is there an automatic wrapping method for strings?
    puts "\n\n**********************************************************\n* Succesfully bootstrapped CBAC. The specified user (##{adminuser}) *\n* may now visit the cbac administration pages, which are *\n* located at the URL /cbac/permissions/index by default  *\n**********************************************************\n\n"
  end

  desc 'Extract a snapshot of the current authorization settings, which can later be restored using the restore_snapshot task. Parameter SNAPSHOT_NAME determines where the snapshot is stored'
  task :extract_snapshot => :environment do
    if ENV['SNAPSHOT_NAME'].nil?
      puts "Missing argument SNAPSHOT_NAME. Substituting timestamp for SNAPSHOT_NAME"
      require 'date'
      ENV['SNAPSHOT_NAME'] = DateTime.now.strftime("%Y%m%d%H%M%S")
    end

    if File::exists?(ENV['SNAPSHOT_NAME']) # Directory already exists!
      if ENV['FORCE'] == "true"
        puts "FORCE specified - overwriting older snapshot with same name."
      else
        puts "A snapshot with the given name already exists, and overwriting is dangerous. Specify FORCE=true to override this check"
        exit
      end
    else # Directory does not exist yet
      FileUtils.mkdir(ENV['SNAPSHOT_NAME'])
    end

    puts "Extracting CBAC permissions to #{ENV['SNAPSHOT_NAME']}"

    # Don't need privilege sets since they are loaded from a config file.
    staged_changes = select_all "cbac_staged_changes"
    dump_objects_to_yaml_file(staged_changes, "staged_changes")

    permissions = select_all "cbac_permissions"
    dump_permissions_to_yaml_file(permissions)

    generic_roles = select_all "cbac_generic_roles"
    dump_objects_to_yaml_file(generic_roles, "generic_roles")

    memberships = select_all "cbac_memberships"
    dump_objects_to_yaml_file(memberships, "memberships")

    known_permissions = select_all "cbac_known_permissions"
    dump_objects_to_yaml_file(known_permissions, "known_permissions")
  end

  desc 'Restore a snapshot of authorization settings that was extracted earlier. Specify a snapshot using SNAPSHOT_NAME'
  task :restore_snapshot => :environment do
    if ENV['SNAPSHOT_NAME'].nil?
      puts "Missing required parameter SNAPSHOT_NAME. Exiting."
      exit
    elsif database_contains_cbac_data?
      if ENV['FORCE'] == "true"
        puts "FORCE specified: emptying CBAC tables"
        clear_cbac_tables
      else
        puts "Reloading snapshot failed: CBAC tables are nonempty. Specify FORCE=true to override this check and empty the tables"
        exit
      end
    end

    puts "Restoring snapshot #{ENV['SNAPSHOT_NAME']}"
    # delegate to db:fixtures:load
    ENV['FIXTURES_PATH'] = ENV['SNAPSHOT_NAME']
    ENV['FIXTURES'] = "cbac_generic_roles,cbac_memberships,cbac_known_permissions,cbac_permissions"
    Rake::Task["db:fixtures:load"].invoke
    puts "Successfully restored snapshot."
    #TODO: check if rake task was successful. else
    #  puts "Restoring snapshot failed."
    #end
  end

  desc ''
  task :pristine => :environment do
    if database_contains_cbac_data?
      if ENV['FORCE'] == "true"
        puts "FORCE specified: emptying CBAC tables"
      else
        puts "CBAC pristine failed: CBAC tables are nonempty. Specify FORCE=true to override this check and empty the tables"
        exit
      end
    end

    if ENV['SKIP_SNAPSHOT'] == 'true'
      puts "\nSKIP_SNAPSHOT provided - not dumping database."
    else
      puts "\nDumping a snapshot of the database"
      Rake::Task["cbac:extract_snapshot"].invoke
    end
    clear_cbac_tables

    puts "\nFirst, bootstrapping CBAC"
    Rake::Task["cbac:bootstrap"].invoke

    filename = ENV['PRISTINE_FILE'] || "config/cbac.pristine"
    pristine_set = parse_pristine_file(filename)
    load_changes_into_database(pristine_set)
  end

  desc ''
  task :upgrade => :environment do
    Rake::Task["cbac:extract_snapshot"].invoke unless ENV['SKIP_SNAPSHOT'] == "true"
    # TODO: delegate reading files to separate function
    # TODO: delegate all new lines to load_changes
  end
end