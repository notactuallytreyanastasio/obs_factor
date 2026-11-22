defmodule ObsFactor.Builder.Source do
  @moduledoc """
  Primitive 3, the source: a shallow clone of a public GitHub repository at
  a branch or tag. Only `https://github.com/<owner>/<repo>` URLs are taken:
  no other host, no ssh, nothing a URL could smuggle into git's arguments.
  """

  alias ObsFactor.Builder.Shell

  @repo ~r{^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?(\.git)?/?$}
  @ref ~r"^[A-Za-z0-9._/-]{1,100}$"

  def valid_repo?(url), do: is_binary(url) and Regex.match?(@repo, url)
  def valid_ref?(ref), do: ref in [nil, ""] or (is_binary(ref) and Regex.match?(@ref, ref) and not String.starts_with?(ref, "-"))

  def dir(cfg, name), do: Path.join([cfg.apps_dir, name, "src"])

  def clone(cfg, name, repo, ref, log) do
    dir = dir(cfg, name)
    File.rm_rf!(dir)
    File.mkdir_p!(Path.dirname(dir))
    branch = if ref in [nil, ""], do: [], else: ["--branch", ref]
    args = ["clone", "--depth", "1", "--single-branch"] ++ branch ++ ["--", String.trim_trailing(repo, "/"), dir]

    with {:ok, _} <- Shell.run("git", args, [timeout: 300_000], log),
         {:ok, [sha | _]} <- Shell.run("git", ["-C", dir, "rev-parse", "HEAD"], [], log) do
      {:ok, String.trim(sha)}
    else
      {:error, msg, _} -> {:error, "git: #{msg}"}
    end
  end
end
