import $ from "jquery";

const pageActionsContainer = document.querySelector(
  "#mfa-page-actions"
) as HTMLDivElement;

function updatePageActions() {
  $.ajax({
    url: window.CMSScriptURI,
    data: {
      __mode: "mfa_page_actions",
    },
  }).then(
    ({
      result: { page_actions: pageActions },
    }: {
      result: { page_actions: { label: string; mode: string }[] };
    }) => {
      if (pageActions.length === 0) {
        pageActionsContainer.classList.add("d-none");
        return;
      }

      pageActionsContainer.classList.remove("d-none");
      const ul = pageActionsContainer.querySelector("ul") as HTMLUListElement;
      ul.innerHTML = "";
      pageActions.forEach(({ label, mode }) => {
        const li = document.createElement("li");
        const a = document.createElement("a");
        a.href = `javascript:void(0);`;
        a.innerText = label;
        a.addEventListener("click", (ev) => {
          ev.preventDefault();
          $.fn.mtModal.open(
            `${window.CMSScriptURI}?__mode=${mode}&id=${pageActionsContainer.dataset.authorId}`,
            { large: true }
          );
        });
        li.appendChild(a);
        ul.appendChild(li);
      });
    }
  );
}

updatePageActions();
$(window).on("hidden.bs.modal", updatePageActions);
