#
# Copyright (c) 2014 Red Hat Inc.
#
# This file is part of hammer-cli-import.
#
# hammer-cli-import is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# hammer-cli-import is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with hammer-cli-import.  If not, see <http://www.gnu.org/licenses/>.
#

require 'hammer_cli'
require 'hammer_cli_import'
require 'json'

module HammerCLIImport
  class ImportCommand
    class RepositoryEnableCommand < BaseCommand
      extend ImportTools::Repository::Extend
      include ImportTools::Repository::Include
      include ImportTools::ContentView::Include

      command_name 'repository-enable'
      reportname = 'channels'
      desc "Enable any Red Hat repositories accessible to any Organization (from spacewalk-report #{reportname})."

      option ['--repository-map'],
             'FILE_NAME',
             'JSON file mapping channel-labels to repository information',
             :default => File.expand_path('../../channel_data_pretty.json', File.dirname(__FILE__)) do |filename|
        raise ArgumentError, "Channel-to-repository-map file #{filename} does not exist" unless File.exist? filename
        filename
      end

      option ['--dry-run'],
             :flag,
             'Only show the repositories that would be enabled',
             :default => false

      add_repo_options

      # Required or BaseCommand gets angry at you
      csv_columns 'channel_id', 'channel_label', 'channel_name', 'number_of_packages', 'org_id'
      persistent_maps :organizations, :products,
                      :redhat_repositories, :redhat_content_views, :repositories

      # BaseCommand will read our channel-csv for us
      def import_single_row(row)
        handle_row(row, true)
      end

      def delete_single_row(row)
        handle_row(row, false)
      end

      def handle_row(row, enable)
        if row['org_id'] # Not a Red Hat channel
          info " Skipping #{row['channel_label']} in organization #{row['org_id']}"
          return
        end

        # read_channel_mapping_data will be called only once per subcommand
        @channel_to_repo ||= read_channel_mapping_data(option_repository_map)
        channel_label = row['channel_label']
        channel_id = row['channel_id'].to_i
        repo_set_info = @channel_to_repo[channel_label]

        if repo_set_info.nil? # not mapped channel (like proxy)
          info " Skipping nontransferable #{row['channel_label']}"
          return
        end

        # rely on we see only products in imported organizations
        get_cache(:products).each do |product_id, product|
          rsets = list_server_entities(:repository_sets, {:product_id => product_id})

          rsets.each do |rs|
            next if repo_set_info['set-url'] != rs['contentUrl']

            product_org = lookup_entity_in_cache(:organizations, {'label' => product['organization']['label']})
            composite_rhcv_id = [get_original_id(:organizations, product_org['id']), channel_id]
            if enable
              # Turn on the specific repository
              rh_repo = enable_repos(product_org, product_id, rs['id'], repo_set_info, row)
              next if rh_repo.nil? || option_dry_run?

              # Finally, if requested, kick off a sync
              with_synced_repo rh_repo do
                cv = create_entity(
                  :redhat_content_views,
                  {
                    :organization_id => product_org['id'],
                    :name => row['channel_name'],
                    :description => 'Red Hat channel migrated from Satellite 5',
                    :repository_ids  => [rh_repo['id']]
                  },
                  composite_rhcv_id)
                begin
                  publish_content_view(cv['id'], :redhat_content_views)
                rescue RestClient::Exception => e
                  msg = JSON.parse(e.response)['displayMessage']
                  error "#{e.http_code} trying to publish content-view #{row['channel_name']} :\n #{msg}\n"
                  next
                end
              end
            else
              if @pm[:redhat_content_views][composite_rhcv_id]
                delete_content_view(get_translated_id(:redhat_content_views, composite_rhcv_id), :redhat_content_views)
              end
              disable_repos(product_org, product_id, rs['id'], repo_set_info, channel_label)
            end
          end
        end
      end

      # Hydrate the channel-to-repository-data mapping struct
      def read_channel_mapping_data(filename)
        channel_map = {}

        File.open(filename, 'r') do |f|
          json = f.read
          channel_map = JSON.parse(json)
        end
        return channel_map
      end

      # this way we're able to get from the server, what repositories within a repository-set are enabled
      def find_repo_in_reposet(product_id, repo_set_id, info)
        repos = api_call(
          :repository_sets,
          :available_repositories,
          'product_id' => product_id,
          'id' => repo_set_id)

        return lookup_entity_in_array(repos['results'],
                                      {'substitutions' => {'basearch' => info['arch'], 'releasever' => info['version']}})
      end

      # and this is quite a pain - to get real ids of the enabled repositories
      # search according to the repository name
      def find_enabled_repo(product_id, repo_set_id, repo_name)
        reposet = api_call(
          :repository_sets,
          :show,
          'product_id' => product_id,
          'id' => repo_set_id)

        return lookup_entity_in_array(reposet['repositories'], {'name' => repo_name})
      end

      # Given a repository-set and a channel-to-repo info for that channel,
      # enable the correct repository
      def enable_repos(org, prod_id, repo_set_id, info, row)
        channel_label = row['channel_label']
        channel_id = row ['channel_id'].to_i
        repo = find_repo_in_reposet(prod_id, repo_set_id, info)
        if repo.nil?
          warn "Repository #{info['url']} for (#{info['arch']} x #{info['version']}) not found!"
          return
        end

        if repo['enabled']
          enabled_repo = find_enabled_repo(prod_id, repo_set_id, repo['repo_name'])
          info "Repository '#{repo['repo_name']}' already enabled as #{enabled_repo['id']}."
          return lookup_entity(:redhat_repositories, enabled_repo['id'])
        end

        info "Enabling #{info['url']} for channel #{channel_label} in org #{org['id']}"
        begin
          unless option_dry_run?
            rc = api_call(
              :repository_sets,
              :enable,
              'product_id' => prod_id,
              'id' => repo_set_id,
              'basearch' => info['arch'],
              'releasever' => info['version'])

            original_org_id = get_original_id(:organizations, org['id'])
            map_entity(:redhat_repositories, [original_org_id, channel_id], rc['input']['repository']['id'])
            # store to cache (using lookup_entity, because :redhat_repositories api
            # does not return full repository hash)
            return lookup_entity(:redhat_repositories, rc['input']['repository']['id'], true)
          end
        rescue RestClient::Exception  => e
          if e.http_code == 409
            info '...already enabled.'
          else
            error "...repository enablement failed with error '#{e.http_code}, #{e.message}' - skipping."
          end
        end
      end

      def disable_repos(org, prod_id, repo_set_id, info, channel_label)
        repo = lookup_entity_in_cache(
          :redhat_repositories,
          {
            'content_id' => repo_set_id,
            'organization' => {'label' => org['label']}
          })
        unless repo
          error "Unknown repository (#{channel_label} equivalent) to disable."
          return
        end
        info "Disabling #{info['url']} for channel #{channel_label} in org #{org['id']}"
        begin
          unless option_dry_run?
            rc = api_call(
              :repository_sets,
              :disable,
              'product_id' => prod_id,
              'id' => repo_set_id,
              'basearch' => info['arch'],
              'releasever' => info['version'])

            unmap_entity(:redhat_repositories, rc['input']['repository']['id'])
            get_cache(:redhat_repositories).delete(rc['input']['repository']['id'])
            return rc['input']['repository']
          end
        rescue RestClient::Exception  => e
          if e.http_code == 404
            error '...no such repository to disable.'
          else
            error "...repository disable failed with error '#{e.http_code}, #{e.message}' - skipping."
          end
        end
      end

      def post_import(_file)
        HammerCLI::EX_OK
      end
    end
  end
end
# vim: autoindent tabstop=2 shiftwidth=2 expandtab softtabstop=2 filetype=ruby
