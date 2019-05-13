##########################################################################
# Copyright 2017 ThoughtWorks, Inc.
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
##########################################################################

default_action :create if defined?(default_action)

property :service_action, [Symbol, Array], required: false, default: [:enable, :start]

property :agent_name, String, name_property: true, required: false

property :user, String, required: false, default: 'go'
property :group, String, required: false, default: 'go'
property :go_server_url, String, required: false
property :daemon, [TrueClass, FalseClass], required: false, default: node['gocd']['agent']['daemon']
property :vnc, [TrueClass, FalseClass], required: false, default: node['gocd']['agent']['vnc']['enabled']
property :autoregister_key, [String, nil], required: false, default: nil
property :autoregister_hostname, [String, nil], required: false, default: nil
property :autoregister_environments, required: false, default: nil
property :autoregister_resources, required: false, default: nil
property :workspace, [String, nil], required: false, default: nil
property :elastic_agent_id, [String, nil], required: false, default: nil
property :elastic_agent_plugin_id, [String, nil], required: false, default: nil

action :create do
  log 'Warn obsolete attributes' do
    message "Please note that node['gocd']['agent']['go_server_host'] and node['gocd']['agent']['go_server_port'] have been replaced by node['gocd']['agent']['go_server_url']"
    level :warn
    only_if { !node['gocd']['agent']['go_server_host'].nil? || !node['gocd']['agent']['go_server_port'].nil? }
  end

  include_recipe 'gocd::agent_linux_install'

  agent_name = new_resource.agent_name
  workspace = new_resource.workspace || "/var/lib/#{agent_name}"
  log_directory = "/var/log/#{agent_name}"
  [workspace, log_directory].each do |d|
    directory d do
      mode 0755
      owner new_resource.user
      group new_resource.group
    end
  end
  directory "#{workspace}/config" do
    mode 0700
    owner new_resource.user
    group new_resource.group
  end

  autoregister_values = agent_properties
  autoregister_values[:key] = new_resource.autoregister_key || autoregister_values[:key]
  autoregister_values[:go_server_url] = new_resource.go_server_url || autoregister_values[:go_server_url]
  autoregister_values[:vnc] = new_resource.vnc || autoregister_values[:vnc]
  autoregister_values[:daemon] = new_resource.daemon || autoregister_values[:daemon]
  autoregister_values[:workspace] = workspace
  autoregister_values[:log_directory] = log_directory
  if autoregister_values[:go_server_url].nil?
    autoregister_values[:go_server_url] = 'https://localhost:8154/go'
    Chef::Log.warn("Go server not found on Chef server or not specifed via node['gocd']['agent']['go_server_url'] attribute, defaulting Go server to #{autoregister_values[:go_server_url]}")
  end

  case node['gocd']['agent']['type']
  when 'java'
    proof_of_registration = "#{workspace}/config/guid.txt"
    autoregister_file_path = "#{workspace}/config/autoregister.properties"
    # package manages the init.d/go-agent script so cookbook should not.
    bash "setup init.d for #{agent_name}" do
      code <<-EOH
      cp /etc/init.d/go-agent /etc/init.d/#{agent_name}
      sed -i 's/# Provides: go-agent$/# Provides: #{agent_name}/g' /etc/init.d/#{agent_name}
      EOH
      not_if "grep -q '# Provides: #{agent_name}$' /etc/init.d/#{agent_name}"
      only_if { agent_name != 'go-agent' }
    end
    link "/usr/share/#{agent_name}" do
      to '/usr/share/go-agent'
      not_if { agent_name == 'go-agent' }
    end
  when 'golang'
    proof_of_registration = "#{workspace}/config/agent-id"
    autoregister_file_path = "#{workspace}/config/autoregister.sh" if autoregister_values[:key]

    template "/etc/init.d/#{agent_name}" do
      cookbook 'gocd'
      source 'golang-agent-init.erb'
      owner 'root'
      group 'root'
      mode 0755
      variables(agent_name: agent_name, autoregister_file: autoregister_file_path)
    end
  end

  template "/etc/default/#{agent_name}" do
    source 'go-agent-default.erb'
    cookbook 'gocd'
    mode '0644'
    owner 'root'
    group 'root'
    notifies :restart, "service[#{agent_name}]" if autoregister_values[:daemon]
    variables autoregister_values
  end

  if autoregister_values[:key]
    gocd_agent_autoregister_file autoregister_file_path do
      owner new_resource.user
      group new_resource.group
      autoregister_key new_resource.autoregister_key
      autoregister_hostname new_resource.autoregister_hostname
      autoregister_environments new_resource.autoregister_environments
      autoregister_resources new_resource.autoregister_resources
      elastic_agent_id new_resource.elastic_agent_id
      elastic_agent_plugin_id new_resource.elastic_agent_plugin_id
      not_if { ::File.exist? proof_of_registration }
      notifies :restart, "service[#{agent_name}]" if autoregister_values[:daemon]
    end
  end

  case node['gocd']['agent']['type']
  when 'java'
    service agent_name do
      provider Chef::Provider::Service::Systemd if platform?('ubuntu') && node['platform_version'].to_f >= 16.04
      supports status: true, restart: autoregister_values[:daemon], start: true, stop: true
      action   new_resource.service_action
    end
  when 'golang'
    service agent_name do
      supports restart: true, start: true, stop: true
      action   new_resource.service_action
    end
  end
end
