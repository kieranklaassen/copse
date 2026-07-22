# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Development dependencies live here, never in the gemspec (KTD6). The gem itself
# declares zero dependencies of any kind.
gem "rake", "~> 13.0"
gem "minitest", "~> 5.25"

# Needed to boot a minimal Rails::Application in the railtie tests (U6).
# actionmailer is here so the mailer guard is actually exercised -- reaching Action
# Mailer through ActiveSupport.on_load rather than config.action_mailer is a
# deliberate decision, and it is only proven by an app that loads it.
gem "railties", ">= 7.1"
gem "actionmailer", ">= 7.1"

# Needed so the teardown tests in U1 actually run rather than skipping. Copse
# invokes foreman as a subprocess and never requires it, so this is a test
# dependency only -- it is deliberately absent from the gemspec.
gem "foreman", ">= 0.90.0"
