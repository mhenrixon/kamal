# No .dockerignore means the whole working tree is shipped to the builder: .git, test
# artifacts, node_modules, and whatever else happens to be lying around.
class Dash::Dockerfile::Rules::MissingDockerignore < Dash::Dockerfile::Rules::Base
  SUGGESTION = "add a .dockerignore covering .git and any build or dependency directories"

  def findings
    return [] if context_dir.nil? || dockerignore

    [ warning(Dash::Dockerfile::Dockerignore::FILENAME, "the build context has no .dockerignore, so everything in it is sent to the builder", SUGGESTION) ]
  end
end
