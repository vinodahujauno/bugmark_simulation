#!/usr/bin/env ruby

# ----- setup -----

Dir.chdir File.expand_path(__dir__)
require_relative '../../Base/lib/dotenv'
TRIAL_DIR = dotenv_trial_dir(__dir__)

# ----- libraries -----

require_relative '../../Base/lib/exchange'
require_relative '../../Base/lib/trial_settings'
require_relative "./../webapp/app_helpers"

# make function for queue_add_task
AppHelpers.module_eval do
  module_function(:queue_add_task)
  public :queue_add_task
end

# require 'awesome_print'
# require 'securerandom'
# require ./user_gen_scr_setting
# require 'yaml'
#require 'whenever'
# ----- info -----

# puts "EXCHANGE_DIR=#{Exchange.src_dir}"
#puts 'EXERCISE SETTINGS'
#ap TrialSettings.settings
puts "Simulate randomized user behavior"

# ----- load -----

# puts 'LOADING RAILS'
Exchange.load_rails

# ----- read settings -----

# settings = YAML.load_file('nightly_scr_setting.yml')
# settings_issue_gen = YAML.load_file('issue_gen_scr_setting.yml')
# settings_skill = YAML.load_file('skill.yml')

# days in future that offers expire and contracts mature
MATURATION_DAYS_IN_FUTURE = 3
# funder price
UNFIXED_PRICE = 1.0
# volume of contracts in tokens
CONTRACT_VOLUME = 100
# number of offers a funder creates
NEW_OFFERS_PER_FUNDER = 3

# ----- users -----
  funders = []
  workers = []

  User.all.each do |user|
    funders.push(user.uuid) if user.jfields['type'] == 'funder'
    workers.push(user.uuid) if user.jfields['type'] == 'worker'
  end

for i in 1..9 do
  funder_ran = 0
  workers_ran = 0
  new_offers_ran = 0
  STDOUT.write "\rrun #{i}: #{new_offers_ran}/#{NEW_OFFERS_PER_FUNDER} offers x #{funder_ran}/#{funders.length} funders  | #{workers_ran}/#{workers.length} workers"
  STDOUT.flush
  # how many workers need their turn and want to do more
  do_more = 0

  # funders randomly fund issues several times per turn
  NEW_OFFERS_PER_FUNDER.times do
    # update output
    funder_ran = 0
    new_offers_ran += 1
    STDOUT.write "\rrun #{i}: #{new_offers_ran}/#{NEW_OFFERS_PER_FUNDER} offers x #{funder_ran}/#{funders.length} funders  | #{workers_ran}/#{workers.length} workers"
    STDOUT.flush
    # choose order in which workers go randomly
    workers.shuffle.each do |funder_uuid|
      # update output
      funder_ran += 1
      STDOUT.write "\rrun #{i}: #{new_offers_ran}/#{NEW_OFFERS_PER_FUNDER} offers x #{funder_ran}/#{funders.length} funders  | #{workers_ran}/#{workers.length} workers"
      STDOUT.flush
      # get a random open issue
      issue_uuid = Issue.where(stm_status: 'open').order('random()').first.uuid
      # args is a hash
      args  = {
        user_uuid: funder_uuid,
        price: UNFIXED_PRICE,  # always fixed price 1
        volume: CONTRACT_VOLUME,
        stm_issue_uuid: issue_uuid,
        expiration: BugmTime.end_of_day(MATURATION_DAYS_IN_FUTURE),
        maturation: BugmTime.end_of_day(MATURATION_DAYS_IN_FUTURE)
      }
      FB.create(:offer_bu, args)
    end
  end


  workers.shuffle.each do |worker_uuid|
    # update output
    workers_ran += 1
    STDOUT.write "\rrun #{i}: #{new_offers_ran}/#{NEW_OFFERS_PER_FUNDER} offers x #{funder_ran}/#{funders.length} funders  | #{workers_ran}/#{workers.length} workers"
    STDOUT.flush
    # load user
    user = User.where(uuid: worker_uuid).first

    # check work_queue length, if >=3, then skip turn
    next if Work_queue.where(user_uuid: worker_uuid).where('completed < now()').count >=3
    # indicate that worker is willing to accept more work
    do_more += 1
    # find a task
    task_chosen = false
    # avoid endless loops by limiting tries
    max_tries = 3
    while task_chosen == false
      # count tries backwards
      max_tries -= 1
      # last try
      task_chosen = true if max_tries <= 0

      # get a random open issue
      issue = Issue.where(stm_status: 'open').order('random()').first
      # find a task to work on
      issue.jfields['skill'].to_a.shuffle.each do |task, completed|
        # skip task, if user already chose a task this turn
        next if task_chosen == true
        # skip task, if it is already completed
        next if completed == 1
        # test whether user has skill for this task
        if user.jfields['skill'].include? task then

          # ---- 1) accept a task ----

          # add task to work_queue, use app_helper function
          AppHelpers.queue_add_task(worker_uuid, issue.uuid, task)
          # register, that user chose a task to work on
          task_chosen = true

          # ---- 2) accept open offer, if one exists ----

          # Filter by unassigned, since we want offers that are still up for the taking
          offers = Offer.unassigned
          # then filter by cost<balance to be able to counter the offer
          offers = offers.where('((1 - offers.price)*offers.volume) <= '+user[:balance].to_s)
          # then filter offers for the current issue
          offers = offers.where(stm_issue_uuid: issue.uuid)
          # randomly select an offer
          offer = offers.order('RANDOM()').first
          # accept offer
          if !offer.nil? && offer.valid?
            projection = OfferCmd::CreateCounter.new(offer, {user_uuid: worker_uuid}).project
            counter = projection.offer
            if counter.valid?
              ContractCmd::Cross.new(counter, :expand).project
            end
          end
        end
      end
    end
  end

  # if all workers pass their opportunity, let time go by and wait.
  if do_more == 0
    (1..30).to_a.reverse.each do |j|
      STDOUT.write "\rrun #{i}: #{new_offers_ran}/#{NEW_OFFERS_PER_FUNDER} offers x #{funder_ran}/#{funders.length} funders  | #{workers_ran}/#{workers.length} workers - waiting #{j} "
      STDOUT.flush
      # load user
      sleep(1)
    end
  end
end
puts ""
puts "DONE"