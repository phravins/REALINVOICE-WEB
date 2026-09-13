defmodule RealinvoiceCloudWeb.CoreComponents do
  @moduledoc """
  App-level building blocks that sit alongside SaladUI.

  The component library for this app is [SaladUI](https://hexdocs.pm/salad_ui) —
  buttons, inputs, tables, cards, the sidebar and so on all come from there and
  are imported into every template by `RealinvoiceCloudWeb.html_helpers/0`. This
  module only keeps the few pieces SaladUI does not cover: flash notices, the JS
  show/hide transitions they use, and Ecto error translation.

  Everything here is styled from the design tokens in `assets/css/app.css`, so it
  follows the light/dark theme with the rest of the app.
  """
  use Phoenix.Component
  use Gettext, backend: RealinvoiceCloudWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "fixed top-4 right-4 z-50 w-80 sm:w-96 cursor-pointer",
        "rounded-md border bg-popover px-4 py-3 text-sm shadow-lg",
        @kind == :info && "text-popover-foreground",
        @kind == :error && "border-destructive/40 text-destructive"
      ]}
      {@rest}
    >
      <p :if={@title} class="flex items-center gap-1.5 font-semibold">
        <span :if={@kind == :info} class="hero-information-circle-mini size-4" />
        <span :if={@kind == :error} class="hero-exclamation-circle-mini size-4" />
        {@title}
      </p>
      <p class={["text-muted-foreground", @title && "mt-1"]}>{msg}</p>
      <p class="sr-only">{gettext("close")}</p>
    </div>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(RealinvoiceCloudWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(RealinvoiceCloudWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
