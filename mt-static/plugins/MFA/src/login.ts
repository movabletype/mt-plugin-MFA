import $ from "jquery";

const form = document.querySelector("form") as HTMLFormElement;

let rendered = false;

function renderMFAForm() {
  const data = {};
  form.querySelectorAll("input").forEach((input) => {
    data[input.name] = input.value;
  });
  data["__mode"] = "mfa_login_form";
  $.ajax({
    type: "POST",
    url: form.action,
    data,
    dataType: "json",
  }).then(
    ({
      error,
      result,
    }: {
      error?: string;
      result?: { html?: string; scripts?: string[] };
    }) => {
      if (error) {
        document.querySelectorAll(".alert").forEach((el) => el.remove());
        form.reset();

        const alert = document.createElement("template");
        alert.innerHTML =
          '<div class="row"><div class="col-12"><div class="alert alert-danger" role="alert"></div></div></div>';
        (alert.content.querySelector(".alert") as HTMLDivElement).textContent =
          error;

        const placeholder = document.querySelector("#msg-block");
        placeholder?.parentElement?.insertBefore(
          alert.content,
          placeholder.nextSibling
        );

        return;
      }

      const { html, scripts } = result || {};

      if (!html && (!scripts || scripts.length === 0)) {
        // has not configured MFA.
        form.submit();
        return;
      }

      rendered = true;

      const fieldSelector =
        "#username-field, #password-field, #remember-me, #remember-me + div";
      document
        .querySelectorAll(fieldSelector)
        .forEach((el) => el.classList.add("d-none"));

      const wrap = document.createElement("div");
      wrap.innerHTML = html || "";
      wrap.querySelector("#mfa-cancel")?.addEventListener("click", () => {
        wrap.remove();
        rendered = false;
        document
          .querySelectorAll(fieldSelector)
          .forEach((el) => el.classList.remove("d-none"));
      });
      const placeholder = document.querySelector("#password-field");
      placeholder?.parentElement?.insertBefore(wrap, placeholder.nextSibling);
      const firstInputElement = wrap.querySelector("input");
      if (firstInputElement) {
        firstInputElement.focus();
      }

      (scripts || []).forEach((src) => {
        if (document.querySelector(`script[src="${src}"]`)) {
          return;
        }

        const script = document.createElement("script");
        script.type = "module";
        script.src = src;
        document.body.appendChild(script);
      });
    }
  );
}

form.addEventListener("submit", (ev) => {
  if (rendered) {
    return;
  }

  ev.preventDefault();
  renderMFAForm();
});
