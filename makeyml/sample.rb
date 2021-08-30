'bear-operation-tools'
require 'csv'

class ChassisCommandLine < Thor
  NOT_AVAILABLE = 'N/A'.freeze

  class_option :verbose, type: :boolean

  desc 'gets', 'get chassis list'
  option :status,            type: :string,  aliases: '-s', desc: 'Filter by status, status_pattern: REGISTRATION FULLTEST FULLTES
TING NORMALTEST NORMALTESTING ACTIVE NEEDREPAIR REPAIRING DEPLOYING ERROR DEPLOYDONE FORMATTING DELETED'
  option :flavor_name,       type: :string,  aliases: '-f', desc: 'Filter by flavor_name'
  option :availability_zone, type: :string,  aliases: '-a', desc: 'Filter by availability_zone'
  option :tor_switch_id,     type: :string,  aliases: '-t', desc: 'Filter by tor_switch_id'
  option :conductor_group,   type: :string,  aliases: '-c', desc: 'Filter by conductor_group'
  option :multiline,         type: :boolean, aliases: '-m', desc: 'Display multiline table format'
  option :short,             type: :boolean, aliases: '-S', desc: 'Display short string mode'
  option :deleted_chassis,   type: :boolean, aliases: '-d', desc: 'Display deleted chassis'
  option :chassis_id,        type: :string,                 desc: 'specify chassis by id'
  def gets
    validate_chassis_id(options['chassis_id']) if options['chassis_id'].present?

    threads = []

    threads << Thread.new { Image.gets['images'] }
    threads << Thread.new { Server.gets['servers'] }
    threads << Thread.new do
      if options['deleted_chassis']
        Chassis.gets(deleted: true, chassis_id: options['chassis_id'])
      else
        Chassis.gets(chassis_id: options['chassis_id'])
      end
    end
    threads << Thread.new { Tenant.gets['projects'] }
    threads << Thread.new { Flavor.gets['flavors'] }

    image_list, server_list, chassis_list, tenant_list, flavor_list = threads.map(&:value)

    chassis_list.each do |chassis|
      tenant = tenant_list.find { |t| t['id'] == chassis['tenant_id'] }
      chassis['tenant_name'] = tenant ? tenant['name'] : ''
      server = server_list.find { |s| s['id'] == chassis['server_id'] }
      chassis['server_name'] = server ? server['name'].to_s : ''
      chassis['image_id'] = server ? server['image']['id'].to_s : ''
      chassis['managed_by_service'] = server ? server['managed_by_service'] : nil
      chassis['managed_service_resource_id'] = server ? server['managed_service_resource_id'] : nil
      chassis['image_name'] =
        if chassis['image_id'].blank?
          ''
        else
          image = image_list.find { |i| i['id'] == chassis['image_id'] }
          image ? image['.os.type'] : '(DELETED)'
        end
      flavor = flavor_list.find { |f| f['id'] == chassis['flavor_id'] }
      chassis['flavor_name'] = flavor['name']
      if chassis['workflow'].blank?
        chassis['workflow']['name'] = ''
        chassis['workflow']['id'] = ''
        chassis['workflow']['state'] = ''
        chassis['workflow']['last_executed_state'] = ''
      end
      chassis['bear_monitor'] ||= {}
    end

    filter = options.select { |k, _v| %w[status flavor_name availability_zone tor_switch_id conductor_group].include?(k) }.to_h
    selected_chassis_list = chassis_list
    unless filter.empty?
      # flavor_name to flavor_id
      if filter.key?('flavor_name')
        filter['flavor_id'] = ApiUtils.flavor_id(options['flavor_name'])
        filter.delete('flavor_name')
      end

      selected_chassis_list = chassis_list.select do |chassis|
        filter.all? { |k, v| chassis[k].casecmp(v.downcase).zero? }
      end
    end

    selected_chassis_list.sort_by! { |chassis| chassis['name'] }

    # Shortオプションが付いている場合、以下のようにフォーマットする
    #  uuid
    #    - 先頭13文字のみ表示
    #  server_name, tenant_name 等
    #    - 先頭20文字表示
    #  workflow_state, workflow_last_executed_state
    #    - '__'区切りし不要な情報を排除
    #  managed_by_service
    #    - '-', '_' が含まれる場合は区切って頭文字のみ並べる(dedicated-hypervisor -> dh)
    if options['short']
      selected_chassis_list.each do |c|
        %w[id server_id tenant_id flavor_id image_id managed_service_resource_id].each do |key|
          c[key] = c[key][0, 13] if c[key]
        end
        c['workflow']['id'] = c['workflow']['id'][0, 13]

        c['server_name'] = c['server_name'][0, 20]
        c['tenant_name'] = c['tenant_name'][0, 20]

        c['bear_monitor']['id'] = c['bear_monitor']['id'][0, 13]

        states = c['workflow']['state'].split('__')
        c['workflow']['state'] = states.length == 1 ? states[0] : states[1]

        last_executed_states = c['workflow']['last_executed_state'].split('__')
        c['workflow']['last_executed_state'] = last_executed_states.length == 1 ? last_executed_states[0] : last_executed_states[1
]

        c['managed_by_service'] = c['managed_by_service'].split(/[-_]/).map(&:first).join if /[-_]/ =~ c['managed_by_service']
      end
    end

    if options['multiline']
      table = [
        %w[name hardware flavor_name status image_name server_name managed_service tenant_name bear_monitor_host workflow_name wor
kflow_state],
        %w[id fixed_ip flavor_id operator image_id server_id resource_id tenant_id updated_at workflow_id last_executed_state]
      ]
      selected_chassis_list.inject(table) do |list, cl|
        c = convert_for_display(cl)
        list << :separator
        list << [c['name'], c['hardware'], c['flavor_name'], c['status'], c['image_name'], c['server_name'], c['managed_service'],
 c['tenant_name'], c['bear_monitor_host'], c['workflow_name'], c['workflow_state']]
        list << [c['id'], c['fixed_ip'], c['flavor_id'], c['operator'], c['image_id'], c['server_id'], c['resource_id'], c['tenant
_id'], c['updated_at'], c['workflow_id'], c['last_executed_state']]
      end
      puts Text::Table.new(rows: table, horizontal_boundary: '|', horizontal_padding: 0)
    else
      puts(selected_chassis_list.to_json)
    end
    exit 1 if selected_chassis_list.empty?
  end

  desc 'create', 'create chassis'
  option :yaml, required: true, type: :string, aliases: '-y', desc: 'Create data for target chassis'
  def create
    Chassis.create(options['yaml'])
    puts("Created chassis, chassis_id: , yaml: #{options['yaml']}")
  end

  desc 'update', 'update chassis'
  option :chassis_id, required: true, type: :string, aliases: '-c', desc: 'Update target chassis_id'
  option :yaml,       required: true, type: :string, aliases: '-y', desc: 'Update data for target chassis'
  def update
    Chassis.update(options['chassis_id'], options['yaml'])
    puts("Updated chassis, chassis_id: #{options['chassis_id']}, yaml: #{options['yaml']}")
  end

  desc 'update_status', 'update chassis status'
  option :chassis_id, required: true,  type: :string, aliases: '-c', desc: 'Update target chassis_id'
  option :status,     required: true,  type: :string, aliases: '-s', desc: 'Change status to'
  option :operator,   required: false, type: :string, aliases: '-o', desc: 'Operator(organization or name)'
  def update_status
    Chassis.update_status(options['chassis_id'], options['status'].upcase, options['operator'])
    puts("Updated chassis status, chassis_id: #{options['chassis_id']} status: #{options['status'].upcase}")
  end

  desc 'admin_only', 'update chassis admin_only'
  option :chassis_id, required: true,  type: :string, aliases: '-c', desc: 'Update target chassis_id'
  option :admin_only, required: true,  type: :string, aliases: '-a', desc: 'Change admin_only to'
  option :operator,   required: false, type: :string, aliases: '-o', desc: 'Operator(organization or name)'
  def admin_only
    if /^(true|false)$/ =~ options['admin_only'].downcase
      Chassis.admin_only(options['chassis_id'], options['admin_only'].casecmp('true').zero?, options['operator'])
      puts("Updated chassis admin_only, chassis_id: #{options['chassis_id']} admin_only: #{options['admin_only']}")
    else
      puts("Please specify '--admin_only/-a' parameter as 'true' or 'false'.")
    end
  end

  desc 'generate', 'generate chassis fixtures'
  option :csv,      required: true, type: :string, default: nil, desc: 'path to chassis information csv file.'
  option :template, required: true, type: :string, default: nil, desc: 'path to fixture template file.'
  def generate
    logger = Logger.new(STDOUT)
    csv = CSV.read(options[:csv], headers: true, converters: :numeric, header_converters: :symbol)
    csv.each do |row|
      row[:template] = options[:template]
      logger.info("start to create output/#{row[:chassis_name]}.yml")
      Chassis.generate(row)
      logger.info("success to create output/#{row[:chassis_name]}.yml")
    end
  rescue StandardError => e
    logger.error(e)
  end

  desc 'delete', 'delete chassis'
  option :chassis_id, required: true, type: :string, aliases: '-c', desc: 'Delete target chassis_id'
  def delete
    Chassis.delete(options['chassis_id'])
    puts("Delete chassis, chassis_id: #{options['chassis_id']}")
  end

  private

  def convert_for_display(chassis)
    if options['chassis_id'].nil?
      chassis_hardware_status = chassis['hardware_status']
      chassis_hardware_status.delete('power')
      failure_hardware = chassis_hardware_status.select { |_h, s| s == false }.map { |k, _v| k.upcase[0] }.sort.join('')
      bear_monitor_host = chassis['bear_monitor']['consul_service_id'].to_s
      bear_monitor_updated_at = chassis['bear_monitor']['updated_at'].to_s
      bear_monitor_host.slice!(/_bear-monitor$/)
      begin
        bear_monitor_updated_at = DateTime.parse(bear_monitor_updated_at)
        bear_monitor_updated_at = bear_monitor_updated_at.strftime('%Y-%m-%dT%H:%M:%S')
      rescue ArgumentError
        bear_monitor_updated_at = ''
      end
    else
      failure_hardware = bear_monitor_host = bear_monitor_updated_at = NOT_AVAILABLE
    end
    {
      'name' => (chassis['admin_only'] ? '[admin only]' : '') << chassis['name'],
      'hardware' => failure_hardware,
      'flavor_name' => chassis['flavor_name'],
      'status' => chassis['status'],
      'image_name' => chassis['image_name'],
      'server_name' => chassis['server_name'],
      'managed_service' => chassis['managed_by_service'],
      'tenant_name' => chassis['tenant_name'],
      'bear_monitor_host' => bear_monitor_host,
      'workflow_name' => chassis['workflow']['name'],
      'workflow_state' => chassis['workflow']['state'],
      'id' => chassis['id'],
      'fixed_ip' => chassis['console']['fixed_ip'],
      'flavor_id' => chassis['flavor_id'],
      'operator' => chassis['operator'],
      'image_id' => chassis['image_id'],
      'server_id' => chassis['server_id'],
      'resource_id' => chassis['managed_service_resource_id'],
      'tenant_id' => chassis['tenant_id'],
      'updated_at' => bear_monitor_updated_at,
      'workflow_id' => chassis['workflow']['id'],
      'last_executed_state' => chassis['workflow']['last_executed_state']
    }
  end

  def validate_chassis_id(chassis_id)
    raise ArgumentError, 'chassis_id must be uuid' unless chassis_id =~ /\A\w{8}-\w{4}-\w{4}-\w{4}-\w{12}\z/
  end
end
