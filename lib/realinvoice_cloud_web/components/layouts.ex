defmodule RealinvoiceCloudWeb.Layouts do
  @moduledoc """
  Layouts for the back office.

  Two shells, both built from SaladUI components:

    * `app/1` — the signed-in shell: left sidebar nav, top bar with the page
      title, the theme toggle and the account menu.
    * `auth/1` — the signed-out shell for the login screen: a plain centred
      column, no card, no box.
  """
  use RealinvoiceCloudWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @nav [
    %{key: :dashboard, label: "Dashboard", path: "/", icon: "hero-squares-2x2"},
    %{key: :invoices, label: "Invoices", path: "/invoices", icon: "hero-document-text"},
    %{key: :customers, label: "Customers", path: "/customers", icon: "hero-users"},
    %{key: :items, label: "Items", path: "/items", icon: "hero-cube"},
    %{key: :nodes, label: "Nodes", path: "/nodes", icon: "hero-server-stack"},
    %{key: :settings, label: "Settings", path: "/settings", icon: "hero-cog-6-tooth"}
  ]

  @doc """
  Renders the signed-in application shell.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope} active={:invoices} title="Invoices">
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active, :atom, default: nil, doc: "the sidebar section to highlight"
  attr :title, :string, default: nil, doc: "the page heading shown in the top bar"
  attr :subtitle, :string, default: nil, doc: "an optional line under the heading"

  slot :inner_block, required: true
  slot :actions, doc: "buttons shown on the right of the page heading"

  def app(assigns) do
    assigns = assign(assigns, :nav, @nav)

    ~H"""
    <.sidebar_provider>
      <.sidebar id="main-sidebar" collapsible="icon" class="border-sidebar-border">
        <.sidebar_header class="px-3 py-4">
          <.link navigate={~p"/"} class="flex items-center gap-2.5">
            <span class="flex size-7 shrink-0 items-center justify-center rounded-md bg-primary text-primary-foreground">
              <.icon name="hero-receipt-percent" class="size-4" />
            </span>
            <span class="flex flex-col group-data-[collapsible=icon]:hidden">
              <span class="text-sm font-semibold leading-tight">RealInvoice</span>
              <span class="text-xs leading-tight text-muted-foreground">Back office</span>
            </span>
          </.link>
        </.sidebar_header>

        <.sidebar_content class="px-2">
          <.sidebar_group>
            <.sidebar_group_label>Sections</.sidebar_group_label>
            <.sidebar_group_content>
              <.sidebar_menu>
                <.sidebar_menu_item :for={item <- @nav}>
                  <.nav_link item={item} active={@active} />
                </.sidebar_menu_item>
              </.sidebar_menu>
            </.sidebar_group_content>
          </.sidebar_group>
        </.sidebar_content>

        <.sidebar_footer class="px-3 py-4 group-data-[collapsible=icon]:hidden">
          <p class="text-xs leading-relaxed text-muted-foreground">
            Billing desks are not syncing yet.
          </p>
        </.sidebar_footer>
      </.sidebar>

      <%!-- min-w-0 keeps the main column from being widened past the viewport
      by the scrolling mobile nav's intrinsic width. --%>
      <.sidebar_inset class="min-w-0">
        <%!-- No backdrop-filter on this header: it would become a containing
        block for position:fixed descendants and throw off the account menu. --%>
        <header class="sticky top-0 z-20 flex h-16 shrink-0 items-center gap-3 border-b border-border bg-background px-4 sm:px-8">
          <.sidebar_trigger target="main-sidebar" class="hidden md:inline-flex" />

          <div class="min-w-0 flex-1">
            <h1 :if={@title} class="truncate text-base font-semibold">{@title}</h1>
            <p :if={@subtitle} class="truncate text-xs text-muted-foreground">{@subtitle}</p>
          </div>

          <div class="flex items-center gap-1">
            {render_slot(@actions)}
            <.theme_toggle />
            <.account_menu current_scope={@current_scope} />
          </div>
        </header>

        <.mobile_nav nav={@nav} active={@active} />

        <div class="flex-1 px-4 py-8 sm:px-8">
          {render_slot(@inner_block)}
        </div>
      </.sidebar_inset>
    </.sidebar_provider>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Renders the signed-out shell used by the login screens.

  Deliberately unboxed — the form sits directly on the page background, the same
  treatment the desktop app's login screen uses.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <div class="flex min-h-svh flex-col bg-background">
      <div class="flex items-center justify-between px-6 py-5">
        <div class="flex items-center gap-2.5">
          <span class="flex size-7 items-center justify-center rounded-md bg-primary text-primary-foreground">
            <.icon name="hero-receipt-percent" class="size-4" />
          </span>
          <span class="text-sm font-semibold">RealInvoice</span>
        </div>
        <.theme_toggle />
      </div>

      <div class="flex flex-1 items-center justify-center px-6 pb-24">
        <div class="w-full max-w-sm">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :item, :map, required: true
  attr :active, :atom, default: nil

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@item.path}
      data-active={to_string(@active == @item.key)}
      aria-current={@active == @item.key && "page"}
      class={[
        "peer/menu-button flex h-9 w-full items-center gap-2.5 overflow-hidden rounded-md p-2",
        "text-left text-sm outline-hidden ring-sidebar-ring transition-colors",
        "hover:bg-sidebar-accent hover:text-sidebar-accent-foreground focus-visible:ring-2",
        "data-[active=true]:bg-sidebar-accent data-[active=true]:font-medium",
        "data-[active=true]:text-sidebar-accent-foreground",
        "group-data-[collapsible=icon]:!size-9 group-data-[collapsible=icon]:!p-2"
      ]}
    >
      <span class={[
        @item.icon,
        "size-4 shrink-0",
        @active == @item.key && "bg-sidebar-primary"
      ]} />
      <span class="truncate group-data-[collapsible=icon]:hidden">{@item.label}</span>
    </.link>
    """
  end

  attr :nav, :list, required: true
  attr :active, :atom, default: nil

  defp mobile_nav(assigns) do
    ~H"""
    <nav class="flex gap-1 overflow-x-auto border-b border-border px-4 py-2 md:hidden">
      <.link
        :for={item <- @nav}
        navigate={item.path}
        data-active={to_string(@active == item.key)}
        class={[
          "shrink-0 rounded-md px-2.5 py-1.5 text-xs text-muted-foreground transition-colors",
          "data-[active=true]:bg-accent data-[active=true]:font-medium data-[active=true]:text-accent-foreground"
        ]}
      >
        {item.label}
      </.link>
    </nav>
    """
  end

  attr :current_scope, :map, default: nil

  defp account_menu(assigns) do
    ~H"""
    <div :if={@current_scope}>
      <.dropdown_menu id="account-menu">
        <.dropdown_menu_trigger
          class="flex size-9 items-center justify-center rounded-md transition-colors hover:bg-accent"
          aria-label="Account menu"
        >
          <span class="flex size-7 items-center justify-center rounded-full bg-secondary text-xs font-semibold text-secondary-foreground">
            {initials(@current_scope.user.email)}
          </span>
        </.dropdown_menu_trigger>

        <.dropdown_menu_content align="end" class="w-60">
          <.dropdown_menu_label class="font-normal">
            <span class="block truncate text-sm font-medium">{@current_scope.user.email}</span>
            <span class="block text-xs capitalize text-muted-foreground">
              {@current_scope.user.role}
            </span>
          </.dropdown_menu_label>
          <.dropdown_menu_separator />
          <.menu_link navigate={~p"/settings"} icon="hero-user-circle">Account</.menu_link>
          <.menu_link navigate={~p"/users/settings"} icon="hero-key">
            Email &amp; password
          </.menu_link>
          <.dropdown_menu_separator />
          <.menu_link
            href={~p"/users/log-out"}
            method="delete"
            icon="hero-arrow-right-start-on-rectangle"
            variant="destructive"
          >
            Log out
          </.menu_link>
        </.dropdown_menu_content>
      </.dropdown_menu>
    </div>
    """
  end

  # A dropdown menu entry that is itself a link.
  #
  # SaladUI's own dropdown_menu_item/1 renders a <div> and declares only a
  # global :rest, so it can carry neither navigate nor href/method — and
  # its JS only lets a native click through when the item element *is* an anchor
  # (isNativeLinkItem). This renders <.link> directly with SaladUI's
  # data-part="item" contract and item styling, so navigation and the DELETE
  # log-out both work inside the menu.
  attr :icon, :string, default: nil
  attr :variant, :string, values: ~w(default destructive), default: "default"
  attr :rest, :global, include: ~w(navigate patch href method)
  slot :inner_block, required: true

  defp menu_link(assigns) do
    ~H"""
    <.link
      data-part="item"
      tabindex="0"
      class={[
        "relative flex cursor-default select-none items-center rounded-xs px-2 py-1.5 text-sm",
        "outline-hidden focus:bg-accent focus:text-accent-foreground",
        @variant == "destructive" &&
          "text-destructive focus:bg-destructive/10 focus:text-destructive dark:focus:bg-destructive/20"
      ]}
      {@rest}
    >
      <span :if={@icon} class={[@icon, "mr-2 size-4 shrink-0"]} />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp initials(email) do
    email
    |> String.split(~r/[@._-]/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.upcase(String.first(&1) || ""))
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  A single button that flips between the light and dark themes.

  The work happens in the inline script in `root.html.heex`, which runs before
  first paint, so the preference survives a reload without a flash of the wrong
  palette and keeps working on dead views such as the login page.
  """
  def theme_toggle(assigns) do
    ~H"""
    <button
      type="button"
      class="flex size-9 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-accent hover:text-accent-foreground"
      phx-click={JS.dispatch("phx:set-theme")}
      data-phx-theme="toggle"
      aria-label="Toggle light or dark theme"
    >
      <.icon name="hero-sun" class="size-4 dark:hidden" />
      <.icon name="hero-moon" class="hidden size-4 dark:block" />
    </button>
    """
  end
end
