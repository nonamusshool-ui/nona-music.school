// Behaviour analytics for the public pages (GA4). Sends only technical identifiers:
// section ids, page types, percentages, FAQ question titles — never form values or personal data.
(() => {
  const pageTypes = {
    "/": "home",
    "/guitar/": "guitar",
    "/guitar/kids/": "kids",
    "/guitar/adults/": "adults",
    "/guitar/beginners/": "beginners",
    "/guitar/first-guitar/": "first_guitar",
  };
  const normalizedPath = window.location.pathname.replace(/index\.html$/, "").replace(/\/?$/, "/");
  const pageType = pageTypes[normalizedPath] ?? "other";

  const send = (name, params = {}) => {
    if (typeof window.gtag !== "function") return;
    try {
      window.gtag("event", name, { ...params, page_type: pageType });
    } catch (error) {
      // Analytics must not break the page.
    }
  };

  const safely = (callback) => {
    try {
      callback();
    } catch (error) {
      // Analytics must not break the page.
    }
  };

  // scroll_depth: 25 / 50 / 75 % (90 % is already measured by GA4 enhanced measurement).
  safely(() => {
    const thresholds = [25, 50, 75];
    const sent = new Set();
    let scheduled = false;

    const check = () => {
      scheduled = false;
      const root = document.documentElement;
      const scrollable = root.scrollHeight - window.innerHeight;
      if (scrollable <= 0) return;
      const percent = (window.scrollY / scrollable) * 100;
      thresholds.forEach((threshold) => {
        if (percent >= threshold && !sent.has(threshold)) {
          sent.add(threshold);
          send("scroll_depth", { percent: threshold });
        }
      });
      if (sent.size === thresholds.length) window.removeEventListener("scroll", onScroll);
    };

    const onScroll = () => {
      if (scheduled) return;
      scheduled = true;
      window.setTimeout(check, 100);
    };

    window.addEventListener("scroll", onScroll, { passive: true });
  });

  // section_view: a section is at least half visible (or fills half the screen, for tall sections).
  safely(() => {
    if (typeof window.IntersectionObserver !== "function") return;
    const sectionIds = [
      "about", "program", "how", "prices", "special", "reviews", "faq", "questions",
      "application", "contact", "directions", "guitar-directions", "teachers",
    ];
    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          const halfOfScreen = entry.intersectionRect.height >= window.innerHeight * 0.5;
          if (!entry.isIntersecting || (entry.intersectionRatio < 0.5 && !halfOfScreen)) return;
          observer.unobserve(entry.target);
          send("section_view", { section_name: entry.target.id });
        });
      },
      { threshold: [0, 0.25, 0.5, 0.75, 1] }
    );
    sectionIds.forEach((id) => {
      const section = document.getElementById(id);
      if (section) observer.observe(section);
    });
  });

  // faq_open / teachers_open: first opening of each <details>.
  safely(() => {
    const openedQuestions = new Set();
    document.querySelectorAll("#faq details, #questions details").forEach((details) => {
      details.addEventListener("toggle", () => {
        if (!details.open) return;
        const summary = details.querySelector("summary");
        const question = (summary?.textContent ?? "").trim().slice(0, 100);
        if (openedQuestions.has(question)) return;
        openedQuestions.add(question);
        send("faq_open", { faq_question: question });
      });
    });

    const teachers = document.getElementById("teachers");
    if (teachers?.tagName === "DETAILS") {
      let teachersSent = false;
      teachers.addEventListener("toggle", () => {
        if (!teachers.open || teachersSent) return;
        teachersSent = true;
        send("teachers_open");
      });
    }
  });

  // Video (only /guitar/): start, 25 / 50 / 75 %, complete.
  safely(() => {
    if (pageType !== "guitar") return;
    document.querySelectorAll("video").forEach((video) => {
      const params = { video_title: "Milonga" };
      const sentPercents = new Set();
      let started = false;
      video.addEventListener("play", () => {
        if (started) return;
        started = true;
        send("video_start", params);
      });
      video.addEventListener("timeupdate", () => {
        if (!video.duration || !Number.isFinite(video.duration)) return;
        const percent = (video.currentTime / video.duration) * 100;
        [25, 50, 75].forEach((threshold) => {
          if (percent >= threshold && !sentPercents.has(threshold)) {
            sentPercents.add(threshold);
            send("video_progress", { ...params, video_percent: threshold });
          }
        });
      });
      let completed = false;
      video.addEventListener("ended", () => {
        if (completed) return;
        completed = true;
        send("video_complete", params);
      });
    });
  });

  // internal_nav_click: links to other pages of this site.
  safely(() => {
    document.addEventListener("click", (event) => {
      safely(() => {
        const link = event.target instanceof Element ? event.target.closest("a[href]") : null;
        if (!link || link.hasAttribute("data-open-application") || link.hasAttribute("data-package")) return;
        if ((link.getAttribute("href") ?? "").startsWith("#")) return;
        const url = new URL(link.href, window.location.href);
        if (url.origin !== window.location.origin || url.pathname === window.location.pathname) return;

        let linkLocation = "content";
        if (link.closest(".direction-card")) linkLocation = "direction_card";
        else if (link.closest("nav, header")) linkLocation = "navigation";
        else if (link.closest("footer")) linkLocation = "footer";
        send("internal_nav_click", { link_location: linkLocation, target_path: url.pathname });
      });
    });
  });
})();
