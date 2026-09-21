/*
 * hellotest - smallest possible native webOS (PDK) app.
 *
 * Proves the whole chain works: cross-compile -> package -> install -> run.
 * It uses the same software-framebuffer approach KOReader will need:
 * draw into a pixel buffer, then flip it to the screen.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <SDL.h>
#include <PDL.h>

#define LOGFILE "/media/internal/com.koreader.hellotest.log"

/* Launcher-launched PDK apps lose stdout/stderr, so send them to a file. */
static void redirect_logs(void)
{
    FILE *lf = fopen(LOGFILE, "w");
    if (lf) {
        dup2(fileno(lf), 1);
        dup2(fileno(lf), 2);
        fclose(lf);
        setvbuf(stdout, NULL, _IONBF, 0);
        setvbuf(stderr, NULL, _IONBF, 0);
    }
}

static void draw_frame(SDL_Surface *screen, int touch_x, int touch_y, int touching)
{
    static const Uint8 bars[7][3] = {
        {255, 255, 255}, {255, 255, 0}, {0, 255, 255}, {0, 255, 0},
        {255, 0, 255},   {255, 0, 0},   {0, 0, 255}
    };
    int i, bar_w = screen->w / 7;

    for (i = 0; i < 7; i++) {
        SDL_Rect r;
        r.x = i * bar_w;
        r.y = 0;
        r.w = (i == 6) ? screen->w - r.x : bar_w;
        r.h = screen->h;
        SDL_FillRect(screen, &r,
                     SDL_MapRGB(screen->format, bars[i][0], bars[i][1], bars[i][2]));
    }

    if (touching) {
        SDL_Rect sq;
        sq.x = touch_x - 40;
        sq.y = touch_y - 40;
        sq.w = 80;
        sq.h = 80;
        SDL_FillRect(screen, &sq, SDL_MapRGB(screen->format, 0, 0, 0));
        sq.x += 6; sq.y += 6; sq.w -= 12; sq.h -= 12;
        SDL_FillRect(screen, &sq, SDL_MapRGB(screen->format, 255, 255, 255));
    }
}

int main(int argc, char **argv)
{
    SDL_Surface *screen;
    SDL_Event ev;
    int running = 1, touching = 0, tx = 0, ty = 0, dirty = 1;
    int i, taps = 0;
    Uint32 start;

    redirect_logs();
    printf("hellotest starting\n");
    for (i = 0; i < argc; i++)
        printf("argv[%d] = %s\n", i, argv[i]);

    PDL_Init(0);                                   /* must come before SDL_Init */
    PDL_SetTouchAggression(PDL_AGGRESSION_MORETOUCHES);
    PDL_GesturesEnable(PDL_FALSE);

    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        printf("SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }

    screen = SDL_SetVideoMode(1024, 768, 16, SDL_SWSURFACE | SDL_FULLSCREEN);
    if (!screen) {
        printf("SDL_SetVideoMode failed: %s\n", SDL_GetError());
        SDL_Quit();
        return 1;
    }
    printf("screen: %dx%d, %d bits per pixel, pitch %d\n",
           screen->w, screen->h, screen->format->BitsPerPixel, screen->pitch);

    start = SDL_GetTicks();
    while (running) {
        while (SDL_PollEvent(&ev)) {
            switch (ev.type) {
            case SDL_QUIT:
                running = 0;
                break;
            case SDL_MOUSEBUTTONDOWN:
                touching = 1; tx = ev.button.x; ty = ev.button.y; dirty = 1;
                taps++;
                printf("touch down #%d at %d,%d (finger %d)\n", taps, tx, ty, ev.button.which);
                break;
            case SDL_MOUSEMOTION:
                if (touching) { tx = ev.motion.x; ty = ev.motion.y; dirty = 1; }
                break;
            case SDL_MOUSEBUTTONUP:
                touching = 0; dirty = 1;
                break;
            case SDL_ACTIVEEVENT:
                printf("active event: gain=%d state=%d\n", ev.active.gain, ev.active.state);
                dirty = 1;
                break;
            }
        }

        if (dirty) {
            draw_frame(screen, tx, ty, touching);
            SDL_Flip(screen);
            dirty = 0;
        }

        /* Auto-quit after 5 minutes so a forgotten test never runs forever. */
        if (SDL_GetTicks() - start > 5 * 60 * 1000)
            running = 0;

        SDL_Delay(15);
    }

    printf("hellotest exiting\n");
    SDL_Quit();
    PDL_Quit();
    return 0;
}
