# vim: autoindent tabstop=2 shiftwidth=2 expandtab softtabstop=2 filetype=ruby
require 'hammer_cli'
require 'set'

module HammerCLIImport
  class ImportCommand
    class LocalRepositoryImportCommand < BaseCommand
      command_name 'content-view'
      desc 'Create content-views based on local/cloned channels.'

      csv_columns 'org_id', 'channel_id', 'channel_label', 'channel_name'

      persistent_maps :organizations, :repositories, :local_repositories, :custom_channels, :products

      option ['--dir'], 'DIR', 'Export directory'

      def directory
        option_dir || File.dirname(option_csv_file)
      end

      # Couple of possible encodings.... (+ matching decodings) (Haskell-ish syntax)
      #
      # > sqrtBig n = head . dropWhile ((n<).(^2)) $ iterate f n where
      # >     f x = (x + n `div` x) `div` 2
      #
      # > enc1 x y = (x + y)*(x + y + 1) `div` 2 + x
      #
      # > dec1 0 = (0,0)
      # > dec1 n = (c, a+d-c) where
      # >     a = sqrtBig (n*2)
      # >     b = n - enc1 0 (a)
      # >     c = (a + b) `mod` a
      # >     d = b `div` a
      #
      # > enc2 x y = 2^x * (y*2+1)
      #
      # > dec2 n = (x,y) where
      # >     (x, y') = f 0 n where
      # >         f a b = if m == 0 then f (a+1) d else (a,b) where (d, m) = b `divMod` 2
      # >     y = (y' - 1) `div` 2
      #
      # Choose wisely ;-)
      def encode(a, b)
        - (2**a) * (2 * b + 1)
      end

      #######
      # -> DUPE
      def mk_product_hash(data, product_name)
        {
          :name => product_name,
          :organization_id => get_translated_id(:organizations, data['org_id'])
        }
      end

      def mk_repo_hash(data, product_id)
        {
          :name => "Local-repository-for-#{data['channel_label']}",
          :product_id => product_id,
          :url => 'file://' + File.join(directory, data['org_id'], data['channel_id']),
          :content_type => 'yum'
        }
      end

      def sync_repo(repo)
        action = @api.resource(:repositories).call(:sync, {:id => repo['id']})
        puts 'Sync started!'
        p action
      end
      # <-
      #######

      def repo_synced?(repo)
        info = @api.resource(:repositories).call(:show, {:id => repo['id']})
        return false unless info['sync_state'] == 'finished'
        Time.parse(info['last_sync']) > Time.parse(info['updated_at'])
      end

      def publish_content_view(id)
        puts "Publishing content view with id=#{id}"
        @api.resource(:content_views).call(:publish, {:id => id})
      end

      def mk_content_view_hash(data, repo_ids)
        {
          :name => data['channel_name'],

          # :description => data['description'],
          :description => 'Channel migrated from Satellite 5',

          :organization_id => get_translated_id(:organizations, data['org_id']),
          :repository_ids  => repo_ids
        }
      end

      def newer_repositories(cw)
        last = cw['last_published']
        return true unless last
        last = Time.parse(last)
        cw['repositories'].any? do |repo|
          last < Time.parse(repo['last_sync'])
        end
      end

      def load_custom_channel_info(org_id, channel_id)
        headers = %w(org_id channel_id package_nevra package_rpm_name in_repo in_parent_channel)
        file = File.join directory, org_id.to_s, channel_id.to_s + '.csv'

        repo_ids = Set[]
        parent_channel_ids = Set[]

        CSVHelper.csv_each file, headers do |data|
          parent_channel_ids << data['in_parent_channel']
          repo_ids << data['in_repo']
        end

        [repo_ids.to_a, parent_channel_ids.to_a]
      end

      def add_local_repo(data)
        product_name = 'Local-repositories'
        composite_id = [data['org_id'].to_i, product_name]
        product_hash = mk_product_hash data, product_name
        product_id = create_entity(:products, product_hash, composite_id)['id'].to_i

        repo_hash = mk_repo_hash data, product_id
        local_repo = create_entity :local_repositories, repo_hash, [data['org_id'].to_i, data['channel_id'].to_i]
        local_repo
      end

      def import_single_row(data)
        local_repo = add_local_repo data
        sync_repo local_repo unless repo_synced? local_repo

        repo_ids, _ = load_custom_channel_info data['org_id'].to_i, data['channel_id'].to_i
        repo_ids.delete nil
        repo_ids.map! { |id| get_translated_id :repositories, id.to_i }
        repo_ids.push local_repo['id'].to_i

        repo_ids.collect { |id| lookup_entity :repositories, id } .each do |repo|
          unless repo_synced? repo
            puts "Repository #{repo['label']} is not (fully) synchronized. Retry once synchronization has completed."
            return
          end
        end
        content_view = mk_content_view_hash data, repo_ids

        cw = create_entity :custom_channels, content_view, data['channel_id'].to_i
        publish_content_view cw['id'] if newer_repositories cw
      end
    end
  end
end