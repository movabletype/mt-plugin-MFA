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
      result: { html },
    }: {
      error?: string;
      result: { html?: string };
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

      if (!html) {
        form.submit();
        return;
      }

      rendered = true;

      document
        .querySelectorAll(
          "#username-field, #password-field, #remember-me, #remember-me + div"
        )
        .forEach((el) => el.classList.add("d-none"));

      const wrap = document.createElement("div");
      wrap.innerHTML = html;
      wrap.querySelector("mfa-cancel")?.addEventListener("click", () => {
        wrap.remove();
        rendered = false;
        document
          .querySelectorAll(
            "#username-field, #password-field, #remember-me, #remember-me + div"
          )
          .forEach((el) => el.classList.remove("d-none"));
      });
      const placeholder = document.querySelector("#password-field");
      placeholder?.parentElement?.insertBefore(wrap, placeholder.nextSibling);
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
